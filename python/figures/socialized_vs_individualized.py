"""Port of the plotting section of scripts/FigureScripts/socializedVsIndividualizedCosts.jl.
The simulation/optimization stays in Julia (JuMP/HiGHS) -- this reads the plot-ready
CSV/JSON that script now exports (see data_io.load_mixed_allocation) and reproduces the
line plot (colored via style.four_color_gradient, same palette as the rest of the figures)
with the "Line of Stability" vline.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import matplotlib.pyplot as plt

import style


def plot_socialized_vs_individualized(mixed_allocation_cost_per_mwh_df, clients, negative_excess_step=None):
    final_costs = [mixed_allocation_cost_per_mwh_df[c].iloc[-1] for c in clients]
    cost_order = sorted(range(len(clients)), key=lambda i: final_costs[i])  # low to high
    colors = style.four_color_gradient(len(clients), cost_order)

    fig, ax = plt.subplots()
    for i, c in enumerate(clients):
        ax.plot(
            mixed_allocation_cost_per_mwh_df["step"], mixed_allocation_cost_per_mwh_df[c],
            color=colors[i], linewidth=1,
            label="Individual Consumer Cost" if i == 0 else None,
        )
    if negative_excess_step is not None:
        ax.axvline(
            negative_excess_step, color="red", linestyle="--", linewidth=2,
            label="Line of Stability",
        )
    ax.set_xlabel("Individualization Grade")
    ax.set_ylabel("Imbalance Cost (EUR/MWh)")
    ax.legend(fontsize=8)
    fig.tight_layout()

    return fig
