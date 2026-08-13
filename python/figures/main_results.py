"""Port of plot_results() and plot_cost_difference() (src/Plotting_functions.jl:56-406).

Deliberately excluded: the "Imbalance cost per MWh vs PV Coverage" scatter (p_cost_vs_pv,
src/Plotting_functions.jl:135-153) -- the user asked for this one plot to stay Julia-only.
"Imbalance Cost Ratio vs PV Coverage" (p_cost_ratio_vs_pv) and the plain PV-coverage bar
chart (p_pv_coverage) are distinct plots and ARE ported below.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

import style
from data_io import create_alphabetic_client_mapping, scale_distribution


def _clip_to_period(price_prod_demand_df, start_hour, sim_days):
    df = price_prod_demand_df.reset_index(drop=True)
    start_hour = pd.Timestamp(start_hour)
    start_pos = int((df["HourUTC_datetime"] >= start_hour).idxmax())
    return df.iloc[start_pos : start_pos + sim_days * 24].copy()


def _plot_socialized_vs_individualized(mixed_allocation_df, clients, demand_df, negative_excess_step=None):
    """Port of plot_socialized_vs_individualized (src/Plotting_functions.jl:420-515)."""
    total_demand_by_client = {c: demand_df[c].sum() for c in clients}
    plot_df = pd.DataFrame({"step": mixed_allocation_df["step"]})
    for c in clients:
        denom = total_demand_by_client[c]
        plot_df[c] = -(mixed_allocation_df[c] / denom) if denom else float("nan")

    final_costs = [plot_df[c].iloc[-1] for c in clients]
    cost_order = sorted(range(len(clients)), key=lambda i: final_costs[i])  # low to high
    colors = style.four_color_gradient(len(clients), cost_order)

    fig, ax = plt.subplots()
    for i, c in enumerate(clients):
        ax.plot(
            plot_df["step"], plot_df[c],
            color=colors[i], linewidth=2,
            label="Client Cost" if i == 0 else None,
        )
    if negative_excess_step is not None:
        ax.axvline(
            negative_excess_step, color=style.PALETTE["green"],
            linestyle="--", linewidth=3, label="Line of Stability",
        )
    ax.set_xlabel("Individualization Grade")
    ax.set_ylabel("Imbalance cost [€/MWh]")
    ax.legend(loc="upper left")
    fig.tight_layout()
    return fig


def plot_results(
    allocations,
    price_prod_demand_df,
    client_pv_ownership,
    allocation_costs,
    coalition_costs,
    clients,
    start_hour,
    sim_days,
    allocation_labels,
    wmape,
):
    """Returns {figure_name: matplotlib.figure.Figure}."""
    figures = {}

    day_data = _clip_to_period(price_prod_demand_df, start_hour, sim_days)
    plot_keys = clients
    client_name_mapping = create_alphabetic_client_mapping(clients)
    plot_keys_alphabetic = [client_name_mapping[c] for c in plot_keys]

    skip_allocations = {"MCC", "VCG", "nucleolus"}
    # Order taken from the `allocations` argument (deterministic) rather than Julia's
    # unspecified Dict iteration order, restricted to allocations we actually have costs for.
    allocations = [a for a in allocations if a in allocation_costs and a not in skip_allocations]

    cost_MWh = {a: scale_distribution(allocation_costs[a], day_data, clients) for a in allocations}

    # --- p_fees_MWh ---
    fig, ax = plt.subplots()
    for alloc in allocations:
        label, color = allocation_labels[alloc]
        vals = [-cost_MWh[alloc][k] for k in plot_keys]
        ax.scatter(range(1, len(plot_keys) + 1), vals, label=label, color=color)
    ax.set_xlabel("Client")
    ax.set_ylabel("Imbalance cost [€/MWh]")
    ax.set_xticks(range(1, len(plot_keys) + 1), plot_keys_alphabetic, rotation=45)
    ax.legend()
    fig.tight_layout()
    figures["p_fees_MWh"] = fig

    # --- p_pv_coverage ---
    pv_coverage_ratio = {}
    for client in plot_keys:
        total_demand = day_data[client].sum()
        total_pv_for_client = day_data["SolarMWh"].sum() * client_pv_ownership[client]
        pv_coverage_ratio[client] = (total_pv_for_client / total_demand) * 100

    fig, ax = plt.subplots()
    ax.bar(range(1, len(plot_keys) + 1), [pv_coverage_ratio[c] for c in plot_keys])
    ax.set_title("PV Coverage of Demand")
    ax.set_xlabel("Client")
    ax.set_ylabel("PV Coverage [%]")
    ax.set_xticks(range(1, len(plot_keys) + 1), plot_keys_alphabetic, rotation=45)
    ax.set_ylim(0, 210)
    fig.tight_layout()
    figures["p_pv_coverage"] = fig

    # p_cost_vs_pv ("Imbalance cost per MWh vs PV Coverage") intentionally NOT ported.

    # --- p_cost_vs_wmape (marginal_price only, with best-fit line) ---
    if "marginal_price" in cost_MWh:
        label, color = allocation_labels["marginal_price"]
        x_vals = np.array([wmape[k] for k in plot_keys], dtype=float)
        y_vals = -np.array([cost_MWh["marginal_price"][k] for k in plot_keys], dtype=float)

        fig, ax = plt.subplots()
        ax.scatter(x_vals, y_vals, label=label, color=color)
        if len(x_vals) > 1:
            m, b = np.polyfit(x_vals, y_vals, 1)
            y_pred = m * x_vals + b
            ss_res = np.sum((y_vals - y_pred) ** 2)
            ss_tot = np.sum((y_vals - y_vals.mean()) ** 2)
            r_squared = 1 - ss_res / ss_tot if ss_tot != 0 else float("nan")
            x_range = np.linspace(x_vals.min(), x_vals.max(), 100)
            ax.plot(
                x_range, m * x_range + b,
                label=f"Best Fit (R² = {r_squared:.3f})",
                color=style.PALETTE["green"], linestyle="--", linewidth=2,
            )
        ax.set_xlabel("WMAPE [%]")
        ax.set_ylabel("Imbalance cost [€/MWh]")
        ax.legend()
        fig.tight_layout()
        figures["p_cost_vs_wmape"] = fig

    # --- p_fees_total ---
    fig, ax = plt.subplots()
    for alloc in allocations:
        label, color = allocation_labels[alloc]
        vals = [allocation_costs[alloc][k] for k in plot_keys]
        ax.scatter(range(1, len(plot_keys) + 1), vals, label=label, color=color)
    ax.set_title("Total imbalance cost per client")
    ax.set_xlabel("Client")
    ax.set_ylabel("€")
    ax.set_xticks(range(1, len(plot_keys) + 1), plot_keys_alphabetic, rotation=45)
    ax.legend()
    fig.tight_layout()
    figures["p_fees_total"] = fig

    # --- cost_ratio (allocated cost vs singleton cost, %) ---
    cost_ratio = {}
    for alloc in allocations:
        cost_ratio[alloc] = {
            c: allocation_costs[alloc][c] / coalition_costs[frozenset([c])] * 100
            for c in plot_keys
        }

    ratio_vals_all = [v for alloc in allocations for v in cost_ratio[alloc].values()]
    ratio_y_pad = (max(ratio_vals_all) - min(ratio_vals_all)) * 0.05
    ratio_ylim = (min(ratio_vals_all) - ratio_y_pad, max(ratio_vals_all) + ratio_y_pad)

    fig, axes = plt.subplots(3, 2, figsize=(12, 10))
    for ax, alloc in zip(axes.flat, allocations):
        label, color = allocation_labels[alloc]
        vals = [cost_ratio[alloc][k] for k in plot_keys]
        ax.scatter(range(1, len(plot_keys) + 1), vals, color=color)
        ax.set_title(label)
        ax.set_xlabel("Client")
        ax.set_ylabel("Allocated VS Singleton Cost [%]")
        ax.set_xticks(range(1, len(plot_keys) + 1), plot_keys_alphabetic, rotation=45)
        ax.set_ylim(*ratio_ylim)
    for ax in axes.flat[len(allocations):]:
        ax.set_visible(False)
    fig.tight_layout()
    figures["p_cost_ratio"] = fig

    # --- p_cost_ratio_vs_pv ---
    fig, ax = plt.subplots()
    for alloc in allocations:
        label, color = allocation_labels[alloc]
        x_vals = [pv_coverage_ratio[k] for k in plot_keys]
        y_vals = [cost_ratio[alloc][k] for k in plot_keys]
        ax.scatter(x_vals, y_vals, label=label, color=color)
    ax.set_title("Imbalance Cost Ratio vs PV Coverage")
    ax.set_xlabel("PV Coverage of Demand [%]")
    ax.set_ylabel("%")
    ax.set_ylim(0, 105)
    ax.legend(loc="center left", bbox_to_anchor=(1, 0.5))
    fig.tight_layout()
    figures["p_cost_ratio_vs_pv"] = fig

    # --- p_total_demand ---
    total_MWh_demand = {c: day_data[c].sum() for c in plot_keys}
    fig, ax = plt.subplots()
    ax.bar(range(1, len(plot_keys) + 1), [total_MWh_demand[c] for c in plot_keys], color="black")
    ax.set_xlabel("Client")
    ax.set_ylabel("Total Demand [MWh]")
    ax.set_xticks(range(1, len(plot_keys) + 1), plot_keys_alphabetic, rotation=45)
    fig.tight_layout()
    figures["p_total_demand"] = fig

    # --- p_mixed (socialized vs individualized), only if both allocations present ---
    if "flat_rate" in allocation_costs and "marginal_price" in allocation_costs:
        individualization_steps = np.arange(0, 1.0001, 0.05)
        mixed_allocation_df = pd.DataFrame({"step": individualization_steps})
        for c in clients:
            flat = allocation_costs["flat_rate"][c]
            indiv = allocation_costs["marginal_price"][c]
            mixed_allocation_df[c] = (1 - mixed_allocation_df["step"]) * flat + mixed_allocation_df["step"] * indiv

        from data_io import check_stability

        negative_excess_step = None
        for _, row in mixed_allocation_df.iterrows():
            step_allocation = {c: row[c] for c in clients}
            max_excess_step = check_stability(step_allocation, coalition_costs, clients)
            if max_excess_step < 0:
                negative_excess_step = row["step"]
                break

        figures["p_mixed"] = _plot_socialized_vs_individualized(
            mixed_allocation_df, clients, day_data, negative_excess_step=negative_excess_step
        )

    return figures


def plot_cost_difference(allocation_costs, clients, price_prod_demand_df):
    """Port of plot_cost_difference (src/Plotting_functions.jl:331-406). Returns
    {figure_name: Figure} and prints the same cheapest/most-expensive table to stdout."""
    filtered_allocations = [a for a in allocation_costs if a not in ("flat_rate", "MCC", "VCG")]

    client_name_mapping = create_alphabetic_client_mapping(clients)
    clients_alphabetic = [client_name_mapping[c] for c in clients]

    cost_MWh = {a: scale_distribution(allocation_costs[a], price_prod_demand_df, clients) for a in filtered_allocations}

    cost_percent_increase = {}
    cost_absolute_difference = {}
    table_rows = []
    for client in clients:
        costs = {a: cost_MWh[a][client] for a in filtered_allocations}
        min_alloc = min(costs, key=costs.get)
        max_alloc = max(costs, key=costs.get)
        min_cost, max_cost = costs[min_alloc], costs[max_alloc]

        cost_percent_increase[client] = ((max_cost - min_cost) / min_cost) * 100
        cost_absolute_difference[client] = max_cost - min_cost
        table_rows.append((client_name_mapping[client], min_alloc, min_cost, max_alloc, max_cost))

    figures = {}
    fig, ax = plt.subplots()
    ax.bar(range(1, len(clients) + 1), [cost_percent_increase[c] for c in clients], color="blue")
    ax.set_title("Cost Increase: Percentage")
    ax.set_xlabel("Client")
    ax.set_ylabel("Percentage Increase [%]")
    ax.set_xticks(range(1, len(clients) + 1), clients_alphabetic, rotation=45)
    fig.tight_layout()
    figures["p_cost_diff_percent"] = fig

    fig, ax = plt.subplots()
    ax.bar(range(1, len(clients) + 1), [cost_absolute_difference[c] for c in clients], color="red")
    ax.set_title("Cost Increase: Absolute")
    ax.set_xlabel("Client")
    ax.set_ylabel("Cost Difference [€/MWh]")
    ax.set_xticks(range(1, len(clients) + 1), clients_alphabetic, rotation=45)
    fig.tight_layout()
    figures["p_cost_diff_absolute"] = fig

    print("Client\tCheapest Allocation\tCheapest €/MWh\tMost Expensive Allocation\tMost Expensive €/MWh")
    for name, min_alloc, min_cost, max_alloc, max_cost in table_rows:
        print(f"{name}\t{min_alloc}\t{min_cost:.2f}\t{max_alloc}\t{max_cost:.2f}")

    return figures
