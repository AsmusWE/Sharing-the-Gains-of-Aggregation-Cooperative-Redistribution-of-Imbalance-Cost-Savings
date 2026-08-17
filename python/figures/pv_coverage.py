"""Port of scripts/FigureScripts/PVCoverage.jl.

Unlike the Julia version, this doesn't literally rename DataFrame columns / dict keys to
alphabetic client codes -- it keeps the original client names internally and only uses the
alphabetic mapping for the x-axis tick labels, which produces the same figure."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import matplotlib.pyplot as plt

import style
from data_io import create_alphabetic_client_mapping, sort_clients_by_demand


def plot_pv_coverage(price_prod_demand_df, client_pv_ownership, clients):
    sorted_clients = sort_clients_by_demand(price_prod_demand_df, clients)
    client_name_mapping = create_alphabetic_client_mapping(sorted_clients)
    display_labels = [client_name_mapping[c] for c in sorted_clients]

    total_solar_prod = price_prod_demand_df["SolarMWh"]
    client_pv_coverage = {}
    client_total_demand = {}
    for client in sorted_clients:
        client_pv = (total_solar_prod * client_pv_ownership[client]).sum()
        client_demand = price_prod_demand_df[client].sum()
        client_pv_coverage[client] = client_pv / client_demand
        client_total_demand[client] = client_demand

    demand_values = [client_total_demand[c] for c in sorted_clients]
    pv_values = [client_pv_coverage[c] * 100 for c in sorted_clients]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 8), sharex=True)
    x = range(1, len(sorted_clients) + 1)
    
    # Top subplot: Demand with logarithmic y-axis
    ax1.bar(x, demand_values, color=style.PALETTE["light_green"], label="Demand [MWh]", zorder=3)
    ax1.set_ylabel("Demand [MWh]")
    ax1.set_yscale("log")
    ax1.set_ylim(bottom=10)
    ax1.set_xticks(list(x))
    ax1.tick_params(axis="x", labelbottom=False)
    ax1.grid(axis="y", color="gray", alpha=0.3, linewidth=0.5, zorder=0)

    # Bottom subplot: PV Coverage
    ax2.bar(x, pv_values, color=style.PALETTE["orange"], alpha=1, label="PV Coverage [%]", zorder=3)
    ax2.set_xlabel("Consumer")
    ax2.set_ylabel("PV Coverage [%]")
    ax2.set_xticks(list(x), display_labels, rotation=45)
    ax2.grid(axis="y", color="gray", alpha=0.3, linewidth=0.5, zorder=0)
    
    fig.tight_layout()

    return fig
