"""Port of scripts/FigureScripts/Gains_Of_Aggregation.jl."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import matplotlib.pyplot as plt

import style


def plot_gains_of_aggregation(coalition_costs, clients):
    """`coalition_costs` is a dict keyed by frozenset[str] -> float (see data_io.PlotData).
    Returns a matplotlib Figure."""
    n = len(clients)
    average_cost_ratio = [None] * n
    all_cost_ratios: dict[int, list[float]] = {}

    for i in range(1, n + 1):
        coalitions_of_size_i = [c for c in coalition_costs if len(c) == i]
        cost_ratios = []
        for coalition in coalitions_of_size_i:
            coalition_cost = coalition_costs[coalition]
            singleton_sum = sum(coalition_costs[frozenset([c])] for c in coalition)
            cost_ratios.append(coalition_cost / singleton_sum)
        all_cost_ratios[i] = cost_ratios
        average_cost_ratio[i - 1] = sum(cost_ratios) / len(cost_ratios)

    x_vals, min_vals, max_vals = [], [], []
    for i in range(1, n + 1):
        if all_cost_ratios.get(i):
            x_vals.append(i)
            min_vals.append(min(all_cost_ratios[i]) * 100)
            max_vals.append(max(all_cost_ratios[i]) * 100)

    fig, ax = plt.subplots()
    ax.fill_between(
        x_vals, min_vals, max_vals,
        color=style.PALETTE["sand"], alpha=0.8, linewidth=0,
        label="Relative cost range",
    )
    ax.plot(
        range(1, n + 1), [v * 100 for v in average_cost_ratio],
        marker="o", markersize=3, linewidth=2,
        color=style.PALETTE["light_green"], label="Unweighted average",
    )
    ax.set_xlabel("Number of Clients in Coalition")
    ax.set_ylabel("Relative cost [%]")
    ax.set_xticks(range(1, n + 1))
    plt.setp(ax.get_xticklabels(), rotation=45)
    ax.legend()
    fig.tight_layout()

    return fig
