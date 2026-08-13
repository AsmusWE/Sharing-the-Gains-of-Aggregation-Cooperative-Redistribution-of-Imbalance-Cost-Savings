"""Loaders for the Parquet/JSON/CSV files exported by scripts/ExportPlotData.jl,
scripts/ExportSystemData.jl, and scripts/FigureScripts/socializedVsIndividualizedCosts.jl.

Also hosts 1:1 Python ports of the small pure-computation helpers from src/*.jl that the
figures need but that don't require re-running any Julia simulation/optimization:
sort_clients_by_demand, create_alphabetic_client_mapping, scale_distribution
(src/Plotting_functions.jl), check_stability (src/Game_theoretic_functions.jl:104), and
calculate_wmape (src/Imbalance_functions.jl:268).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from string import ascii_uppercase

import pandas as pd

RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"
CACHE_PY_DIR = RESULTS_DIR / "cache_py"


@dataclass
class PlotData:
    """Mirrors src/Types.jl's SimplePlotData, as reconstructed from an export directory."""

    clients: list[str]
    allocations: list[str]
    start_hour: pd.Timestamp
    sim_days: int
    price_prod_demand_df: pd.DataFrame
    client_pv_ownership: dict[str, float]
    allocation_costs: dict[str, dict[str, float]]
    coalition_costs: dict[frozenset[str], float]
    coalition_imbalances: dict[frozenset[str], list[float]]


def _load_json(path: Path):
    with open(path) as f:
        return json.load(f)


def coalition_key(coalition) -> str:
    """Canonical string key for a coalition, matching Julia's coalition_key() in
    src/Export_functions.jl (sorted, comma-joined client names)."""
    return ",".join(sorted(coalition))


def load_plot_data(cache_name: str) -> PlotData:
    """Load a cache exported by `julia scripts/ExportPlotData.jl <cache_name>.jls`."""
    cache_dir = CACHE_PY_DIR / cache_name
    meta = _load_json(cache_dir / "meta.json")
    price_prod_demand_df = pd.read_parquet(cache_dir / "price_prod_demand.parquet")
    client_pv_ownership = _load_json(cache_dir / "client_pv_ownership.json")
    allocation_costs = _load_json(cache_dir / "allocation_costs.json")
    coalition_costs_raw = _load_json(cache_dir / "coalition_costs.json")
    coalition_imbalances_raw = _load_json(cache_dir / "coalition_imbalances.json")

    coalition_costs = {frozenset(k.split(",")): v for k, v in coalition_costs_raw.items()}
    coalition_imbalances = {
        frozenset(k.split(",")): v for k, v in coalition_imbalances_raw.items()
    }

    return PlotData(
        clients=meta["clients"],
        allocations=meta["allocations"],
        start_hour=pd.Timestamp(meta["start_hour"]),
        sim_days=meta["sim_days"],
        price_prod_demand_df=price_prod_demand_df,
        client_pv_ownership=client_pv_ownership,
        allocation_costs=allocation_costs,
        coalition_costs=coalition_costs,
        coalition_imbalances=coalition_imbalances,
    )


def load_system_data() -> tuple[pd.DataFrame, dict[str, float]]:
    """Load the raw (full-history) export written by `julia scripts/ExportSystemData.jl`."""
    cache_dir = CACHE_PY_DIR / "raw_system_data"
    price_prod_demand_df = pd.read_parquet(cache_dir / "price_prod_demand.parquet")
    client_pv_ownership = _load_json(cache_dir / "client_pv_ownership.json")
    return price_prod_demand_df, client_pv_ownership


def load_mixed_allocation() -> tuple[pd.DataFrame, list[str], float | None]:
    """Load the export written by the modified socializedVsIndividualizedCosts.jl.
    Returns (mixed_allocation_cost_per_mwh_df, clients, negative_excess_step)."""
    cache_dir = CACHE_PY_DIR / "socialized_vs_individualized"
    df = pd.read_csv(cache_dir / "mixed_allocation_cost_per_mwh.csv")
    meta = _load_json(cache_dir / "meta.json")
    return df, meta["clients"], meta["negative_excess_step"]


def sort_clients_by_demand(price_prod_demand_df: pd.DataFrame, clients: list[str]) -> list[str]:
    """Port of sort_clients_by_demand (src/Plotting_functions.jl:23-28): highest total
    demand first."""
    totals = {c: price_prod_demand_df[c].sum() for c in clients}
    return sorted(clients, key=lambda c: -totals[c])


def create_alphabetic_client_mapping(clients: list[str]) -> dict[str, str]:
    """Port of create_alphabetic_client_mapping (src/Plotting_functions.jl:30-45): maps each
    client (in the given order) to a display code A, B, ..., Z, AA, AB, ..."""
    mapping: dict[str, str] = {}
    for idx, client in enumerate(clients, start=1):
        if idx <= len(ascii_uppercase):
            mapping[client] = ascii_uppercase[idx - 1]
        else:
            first_letter_idx = (idx - 1) // 26
            second_letter_idx = (idx - 1) % 26
            mapping[client] = ascii_uppercase[first_letter_idx] + ascii_uppercase[second_letter_idx]
    return mapping


def scale_distribution(
    distribution: dict[str, float], demand_df: pd.DataFrame, clients: list[str]
) -> dict[str, float]:
    """Port of scale_distribution (src/Plotting_functions.jl:47-54): cost per MWh of
    demand for each client."""
    return {c: distribution[c] / demand_df[c].sum() for c in clients}


def check_stability(client_costs: dict[str, float], coalition_costs, clients: list[str]) -> float:
    """Port of check_stability (src/Game_theoretic_functions.jl:104-125): max excess of any
    proper sub-coalition's stand-alone cost over its share of client_costs. `coalition_costs`
    may be a dict keyed by frozenset/tuple/list of client names (any iterable works)."""
    grand_coalition_set = frozenset(clients)
    instabilities = []
    for coalition, coalition_cost in coalition_costs.items():
        coalition_set = frozenset(coalition)
        if coalition_set == grand_coalition_set or not coalition_set:
            continue
        instabilities.append(coalition_cost - sum(client_costs[i] for i in coalition))
    if not instabilities:
        return 0.0
    return max(instabilities)


def calculate_wmape(
    coalition_imbalances: dict[frozenset[str], list[float]],
    price_prod_demand_df: pd.DataFrame,
    client_pv_ownership: dict[str, float],
    coalition,
) -> float:
    """Port of calculate_wmape (src/Imbalance_functions.jl:268-289). `coalition` is either a
    single client name (str) or an iterable of client names (a coalition); this mirrors the
    two call sites' usage more directly than Julia's `length(coalition) == 1` string-length
    check (which happens to work there only because client codes are 1 character)."""
    if isinstance(coalition, str):
        clients = [coalition]
    else:
        clients = list(coalition)

    demand = price_prod_demand_df[clients].sum(axis=1)
    production = price_prod_demand_df["SolarMWh"] * sum(client_pv_ownership[c] for c in clients)
    imbalances = coalition_imbalances[frozenset(clients)]

    total_absolute_error = sum(abs(x) for x in imbalances)
    total_actual = (demand - production).abs().sum()

    return (total_absolute_error / total_actual) * 100
