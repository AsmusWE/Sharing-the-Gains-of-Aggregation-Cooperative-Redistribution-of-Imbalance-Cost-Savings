"""Python entry point replacing scripts/Plotting_main.jl and the three scripts in
scripts/FigureScripts/. Reads the Parquet/JSON/CSV exports written by:

  julia scripts/ExportPlotData.jl [cache_file_name]   (default 22ClientMonthly.jls)
  julia scripts/ExportSystemData.jl
  julia scripts/FigureScripts/socializedVsIndividualizedCosts.jl   (modified to export)

and produces every figure those Julia scripts used to render, minus the "Imbalance cost
per MWh vs PV Coverage" scatter (excluded from the migration by request). Every figure is
saved as a PNG under results/figures/.

Run from the repo root: `python python/plotting_main.py`
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import matplotlib.pyplot as plt

import style
from data_io import (
    calculate_wmape,
    check_stability,
    load_mixed_allocation,
    load_plot_data,
    load_system_data,
    sort_clients_by_demand,
)
from figures import gains_of_aggregation, main_results, pv_coverage, socialized_vs_individualized

# Cache file (see results/cache/, produced by scripts/Imbalance_main.jl) to drive the main
# results figures and the "gains of aggregation" figure. Matches Plotting_main.jl's
# `22ClientMonthly.jls` and Gains_Of_Aggregation.jl's `17ClientWeekly.jls`. Only
# 22ClientMonthly is guaranteed present out of the box; re-run Imbalance_main.jl with a
# different `file_name`/client set and re-export to point this at a different cache.
MAIN_CACHE_NAME = "AllClientMonthly"
GAINS_CACHE_NAME = "AllClientMonthly"

PLOTTED_ALLOCATIONS = [
    "shapley",
    "MCC",
    "VCG",
    "gately",
    "marginal_price",
    "flat_rate",
]

ALLOCATION_LABELS = {
    "shapley": ("Shapley", style.PALETTE["light_green"]),
    "MCC": ("MCC", "black"),
    "MCC_budget_balanced": ("MCC Budget Balanced", "orange"),
    "VCG": ("VCG", "purple"),
    "gately": ("Gately Point", style.PALETTE["sand"]),
    "gately_interval": ("Gately 15Min interval", "lightgrey"),
    "marginal_price": ("Marginal Price", style.PALETTE["orange"]),
    "reduced_cost": ("Asymmetric Price", "blue"),
    "nucleolus": ("Nucleolus", "green"),
    "flat_rate": ("Flat Rate", style.PALETTE["red"]),
}


# Figures wide enough (e.g. a multi-panel grid) to warrant a `figure*` (both columns) in
# the paper, rather than a single-column `figure`.
WIDE_FIGURES = {"p_cost_ratio"}


def _save_all(figures: dict, prefix: str = ""):
    for name, fig in figures.items():
        pgf_width_in = style.PGF_TEXTWIDTH_IN if name in WIDE_FIGURES else None
        path = style.save_figure(fig, f"{prefix}{name}" if prefix else name, pgf_width_in=pgf_width_in)
        print(f"  saved {path}")
        plt.close(fig)


def run_main_results():
    print(f"Loading plot data cache '{MAIN_CACHE_NAME}'...")
    plot_data = load_plot_data(MAIN_CACHE_NAME)

    wmape = {
        client: calculate_wmape(plot_data.coalition_imbalances, plot_data.price_prod_demand_df, plot_data.client_pv_ownership, client)
        for client in plot_data.clients
    }

    clients_sorted = sort_clients_by_demand(plot_data.price_prod_demand_df, plot_data.clients)
    allocations = [a for a in plot_data.allocations if a in PLOTTED_ALLOCATIONS]

    print("Generating main results figures...")
    figures = main_results.plot_results(
        allocations,
        plot_data.price_prod_demand_df,
        plot_data.client_pv_ownership,
        plot_data.allocation_costs,
        plot_data.coalition_costs,
        clients_sorted,
        plot_data.start_hour,
        plot_data.sim_days,
        ALLOCATION_LABELS,
        wmape,
    )
    _save_all(figures)

    print("Generating cost-difference figures...")
    figures = main_results.plot_cost_difference(
        plot_data.allocation_costs, clients_sorted, plot_data.price_prod_demand_df
    )
    _save_all(figures)

    for alloc in plot_data.allocations:
        max_excess = check_stability(plot_data.allocation_costs[alloc], plot_data.coalition_costs, clients_sorted)
        print(f"Max excess for allocation method {alloc}: {max_excess}")


def run_gains_of_aggregation():
    print(f"Loading plot data cache '{GAINS_CACHE_NAME}' for gains-of-aggregation figure...")
    plot_data = load_plot_data(GAINS_CACHE_NAME)
    fig = gains_of_aggregation.plot_gains_of_aggregation(plot_data.coalition_costs, plot_data.clients)
    _save_all({"gains_of_aggregation": fig})


def run_pv_coverage():
    print("Loading raw system data for PV-coverage figure...")
    price_prod_demand_df, client_pv_ownership = load_system_data()
    clients = [c for c in price_prod_demand_df.columns if c in client_pv_ownership]
    fig = pv_coverage.plot_pv_coverage(price_prod_demand_df, client_pv_ownership, clients)
    _save_all({"pv_coverage": fig})


def run_socialized_vs_individualized():
    print("Loading socialized-vs-individualized export...")
    df, clients, negative_excess_step = load_mixed_allocation()
    if negative_excess_step is not None:
        print(f"Individualization grade at the line of stability: {negative_excess_step}")
    else:
        print("Line of stability not reached within the analyzed range")
    fig = socialized_vs_individualized.plot_socialized_vs_individualized(df, clients, negative_excess_step)
    _save_all({"socialized_vs_individualized": fig})


def _try(name, fn):
    try:
        fn()
    except FileNotFoundError as e:
        print(f"Skipping {name}: required export not found ({e}).")
        print("  Run the corresponding Julia export script first (see module docstring).")


def main():
    style.apply_theme()
    _try("main results", run_main_results)
    _try("gains of aggregation", run_gains_of_aggregation)
    _try("PV coverage", run_pv_coverage)
    _try("socialized vs individualized", run_socialized_vs_individualized)


if __name__ == "__main__":
    main()
