# ExportPlotData.jl
# Deserializes a SimplePlotData cache (produced by Imbalance_main.jl) and re-exports it as
# Parquet/JSON files under results/cache_py/<cache-name>/ so it can be read from Python
# (see python/data_io.py). Julia's Serialization format is not readable from Python, hence
# this export step.
#
# Usage: julia scripts/ExportPlotData.jl [cache_file_name]
# Defaults to "22ClientMonthly.jls" (the cache currently checked out under results/cache/)
# if no argument is given.

# --- Project Modules ---
include("common_setup.jl")

# --- External Packages ---
using Serialization

cache_file_name = length(ARGS) >= 1 ? ARGS[1] : "AllClientMonthly.jls"
cache_name = first(splitext(cache_file_name))

plot_data = deserialize(joinpath(@__DIR__, "..", "results", "cache", cache_file_name))

out_dir = joinpath(@__DIR__, "..", "results", "cache_py", cache_name)
export_plot_data(plot_data, out_dir)

println("Exported ", cache_file_name, " to ", out_dir)
