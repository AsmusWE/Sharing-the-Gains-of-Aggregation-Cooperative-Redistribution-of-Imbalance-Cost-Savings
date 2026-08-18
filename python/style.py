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

# Matches the IEEEtran default typesetting (no extra font package -> Computer/Latin Modern
# serif, 10pt body text), so that \input{}-ing a figure's .pgf into the paper renders text
# identically to the surrounding LaTeX. pgf.rcfonts=False stops matplotlib from overriding
# this with system fonts. Applied globally in apply_theme(), not just around the .pgf save:
# axis/tick labels bake in rcParams['font.family'] at the moment ax.set_xlabel() etc. is
# called (inside each figure's plotting function), not at savefig time, so scoping this to
# only the .pgf save left labels in the seaborn default (sans) while tick text -- resolved
# fresh at draw time -- picked up serif, producing a mismatched figure.
PGF_RC = {
    "pgf.texsystem": "pdflatex",
    "font.family": "serif",
    "pgf.rcfonts": False,
    "font.size": 10,
    "axes.labelsize": 10,
    "xtick.labelsize": 10,
    "ytick.labelsize": 10,
    "legend.fontsize": 10,
    # figure.labelsize (used by fig.suptitle/supxlabel/supylabel) defaults to 'large'
    # (~12pt) independently of axes.labelsize -- without pinning it too, a sup-label
    # (e.g. the shared y-axis title on the p_cost_ratio grid) renders visibly larger
    # than the per-axes labels/tick text it sits next to.
    "figure.labelsize": 10,
}

# IEEEtran \columnwidth in inches. The .pgf is rendered at this physical width (preserving
# each figure's on-screen aspect ratio) so it can be \input{} straight into the paper with
# no \resizebox -- resizing after the fact would scale the embedded 10pt text along with
# the box and defeat the point of matching PGF_RC's font size to the paper.
PGF_WIDTH_IN = 3.5

# IEEEtran \textwidth (both columns + the gutter between them) in inches, for figures meant
# to be \input{} inside a `figure*` (spans both columns) rather than a single-column `figure`.
PGF_TEXTWIDTH_IN = 7.16


def apply_theme():
    """Call once at start-up: seaborn base theme with a plain white background/axes,
    styled to match PGF_RC (see there) so on-screen PNGs already preview how the .pgf
    will look in the paper."""
    sns.set_theme(style="white")
    plt.rcParams.update(PGF_RC)
    plt.rcParams["figure.figsize"] = DEFAULT_FIGSIZE
    plt.rcParams["axes.edgecolor"] = "black"
    plt.rcParams["axes.facecolor"] = "white"
    plt.rcParams["figure.facecolor"] = "white"
    plt.rcParams["savefig.facecolor"] = "white"


def save_figure(fig, name, dpi=200, pgf_width_in=None):
    """Save a figure to results/figures/<name>.png and results/figures/<name>.pgf,
    creating the directory if needed. The .pgf is typeset by a local LaTeX install (see
    PGF_RC), at its true print size (PGF_WIDTH_IN by default, or `pgf_width_in` if given --
    pass PGF_TEXTWIDTH_IN for a figure meant to span both columns via `figure*`), so it can
    be \\input{} straight into the paper with no \\resizebox -- resizing after the fact would
    scale the embedded 10pt text along with the box and defeat the point of matching
    PGF_RC's font size to the paper. If that LaTeX pass fails (e.g. an unescaped special
    character), the .pgf is skipped with a warning rather than losing the .png."""
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    path = FIGURES_DIR / f"{name}.png"
    fig.savefig(path, dpi=dpi, bbox_inches="tight")

    pgf_width_in = pgf_width_in or PGF_WIDTH_IN
    pgf_path = FIGURES_DIR / f"{name}.pgf"
    orig_size = fig.get_size_inches()
    orig_hspace = fig.subplotpars.hspace
    orig_wspace = fig.subplotpars.wspace
    pgf_height = pgf_width_in * orig_size[1] / orig_size[0]
    try:
        fig.set_size_inches(pgf_width_in, pgf_height)
        fig.tight_layout()
        # tight_layout() recomputes hspace/wspace from scratch, clobbering any custom
        # subplot spacing (e.g. hspace=0 for stacked, axis-sharing panels) a figure function
        # set intentionally -- restore it after tight_layout has fixed up the outer margins.
        fig.subplots_adjust(hspace=orig_hspace, wspace=orig_wspace)
        fig.savefig(pgf_path)
    except Exception as e:
        print(f"  warning: could not render {pgf_path.name} via LaTeX ({e})")
        pgf_path.unlink(missing_ok=True)
    finally:
        fig.set_size_inches(*orig_size)

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
