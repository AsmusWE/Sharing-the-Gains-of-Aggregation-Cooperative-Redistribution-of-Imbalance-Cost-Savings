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
    # Sort by demand (highest to lowest) and drop the 2 smallest clients, matching
    # PVCoverage.jl's `sort_clients_by_demand(system_data, clients)[1:end-2]`.
    sorted_clients = sort_clients_by_demand(price_prod_demand_df, clients)[:-2]
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

    fig, ax1 = plt.subplots()
    x = range(1, len(sorted_clients) + 1)
    ax1.bar(x, demand_values, color=style.PALETTE["light_green"], label="Demand [MWh]")
    ax1.set_xlabel("Client")
    ax1.set_ylabel("Demand [MWh]")
    ax1.set_xticks(list(x), display_labels, rotation=45)

    ax2 = ax1.twinx()
    ax2.bar(x, pv_values, color=style.PALETTE["orange"], alpha=0.7, label="PV Coverage")
    ax2.set_ylabel("PV Coverage [%]")

    handles1, labels1 = ax1.get_legend_handles_labels()
    handles2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(
        handles1 + handles2, labels1 + labels2,
        loc="upper left", facecolor="white", edgecolor="black",
    )
    fig.tight_layout()

    return fig
