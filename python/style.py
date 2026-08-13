"""Shared color palette and a simple default figure style. Colors mirror the PALETTE_*
constants in src/Plotting_functions.jl (they encode which allocation method is which, so
keeping them consistent matters); exact figure sizes/fonts are not replicated from the
Julia originals -- these are simple, readable defaults meant to be restyled later."""

from pathlib import Path

import matplotlib.pyplot as plt
import seaborn as sns

PALETTE = {
    "light_green": "#96CEB4",
    "sand": "#FFEEAD",
    "orange": "#FFCC5C",
    "red": "#FF6F69",
    "green": "#88D8B0",
}

RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"
FIGURES_DIR = RESULTS_DIR / "figures"

DEFAULT_FIGSIZE = (8, 5)


def apply_theme():
    """Call once at start-up: seaborn base theme with a plain white background/axes."""
    sns.set_theme(style="white")
    plt.rcParams["figure.figsize"] = DEFAULT_FIGSIZE
    plt.rcParams["axes.edgecolor"] = "black"
    plt.rcParams["axes.facecolor"] = "white"
    plt.rcParams["figure.facecolor"] = "white"
    plt.rcParams["savefig.facecolor"] = "white"


def save_figure(fig, name, dpi=200):
    """Save a figure to results/figures/<name>.png, creating the directory if needed."""
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    path = FIGURES_DIR / f"{name}.png"
    fig.savefig(path, dpi=dpi, bbox_inches="tight")
    return path


def linear_gradient(hex_start, hex_end, n):
    """n colors linearly interpolated between two hex colors (inclusive), matching
    Julia's `range(colorant"...", stop=colorant"...", length=n)`."""
    c0 = _hex_to_rgb(hex_start)
    c1 = _hex_to_rgb(hex_end)
    if n == 1:
        return [hex_start]
    return [
        _rgb_to_hex(tuple(c0[k] + (c1[k] - c0[k]) * i / (n - 1) for k in range(3)))
        for i in range(n)
    ]


def four_color_gradient(n_clients, cost_order):
    """Port of the light_green -> sand -> orange -> red gradient built in
    plot_socialized_vs_individualized (src/Plotting_functions.jl:459-489). `cost_order` is
    a 0-indexed list giving, for each rank position (low to high final cost), the client's
    index; returns one color per client, ordered to match the original `clients` list."""
    if n_clients == 1:
        return [PALETTE["light_green"]]
    if n_clients == 2:
        return [PALETTE["light_green"], PALETTE["red"]]
    if n_clients == 3:
        return [PALETTE["light_green"], PALETTE["orange"], PALETTE["red"]]

    n_per_segment, remainder = divmod(n_clients - 1, 3)
    n1 = n_per_segment + (1 if remainder >= 1 else 0) + 1
    n2 = n_per_segment + (1 if remainder >= 2 else 0) + 1
    n3 = n_per_segment + 1

    gradient1 = linear_gradient(PALETTE["light_green"], PALETTE["sand"], n1)
    gradient2 = linear_gradient(PALETTE["sand"], PALETTE["orange"], n2)
    gradient3 = linear_gradient(PALETTE["orange"], PALETTE["red"], n3)

    color_gradient = gradient1[:-1] + gradient2[:-1] + gradient3
    # color_gradient[rank] is the color for the client at that cost rank (low to high);
    # cost_order[rank] is that client's index in the original client list.
    palette_colors = [None] * n_clients
    for rank, client_idx in enumerate(cost_order):
        palette_colors[client_idx] = color_gradient[rank]
    return palette_colors


def _hex_to_rgb(hex_color):
    hex_color = hex_color.lstrip("#")
    return tuple(int(hex_color[i : i + 2], 16) for i in (0, 2, 4))


def _rgb_to_hex(rgb):
    return "#" + "".join(f"{round(c):02X}" for c in rgb)
