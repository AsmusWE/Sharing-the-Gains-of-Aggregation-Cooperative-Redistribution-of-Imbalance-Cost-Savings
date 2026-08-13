# ExportSystemData.jl
# Loads the raw (full-history, unclipped) system data via load_data() and exports it as
# Parquet/JSON under results/cache_py/raw_system_data/ so it can be read from Python
# (see python/data_io.py). Used by the Python port of PVCoverage.jl, which needs the full
# multi-year per-client demand/PV data rather than a specific cached simulation run.

# --- Project Modules ---
include("common_setup.jl")

system_data, clients, _ = load_data()

out_dir = joinpath(@__DIR__, "..", "results", "cache_py", "raw_system_data")
export_system_data(system_data, out_dir)

println("Exported raw system data (", length(clients), " clients) to ", out_dir)
