# Reuses the already-computed AllClientMonthly.jls cache (produced by Imbalance_main.jl)
# instead of re-running the full coalition simulation that socializedVsIndividualizedCosts.jl
# does from scratch. That cache already contains:
#   - coalition_costs for the FULL power set of clients (collect(combinations(clients)) in
#     Imbalance_main.jl), which is exactly what an exact (non-sparse) check_stability needs.
#   - allocation_costs["flat_rate"] and ["gately"], since Imbalance_main.jl computes
#     ALLOCATION_PRESETS[:default], which includes both.
# So this script does no optimization at all -- just interpolation and dict lookups over
# data that's already on disk.
#
# Usage: julia scripts/FigureScripts/socializedVsIndividualizedFromCache.jl [cache_file_name]
# Defaults to "AllClientMonthly.jls".

# --- Project Modules ---
include("../common_setup.jl")

# --- External Packages ---
using DataFrames, CSV, JSON, Serialization

cache_file_name = length(ARGS) >= 1 ? ARGS[1] : "AllClientMonthly.jls"
plot_data = deserialize(joinpath(@__DIR__, "..", "..", "results", "cache", cache_file_name))

clients = plot_data.clients
system_data = plot_data.system_data
allocation_costs = plot_data.allocation_costs
coalition_costs = plot_data.coalition_costs

individualized_allocation = "gately"
socialized_allocation = "flat_rate"

for alloc in (individualized_allocation, socialized_allocation)
    if !haskey(allocation_costs, alloc)
        error("Cache '$cache_file_name' does not contain allocation '$alloc' -- rerun Imbalance_main.jl with a preset that includes it.")
    end
end

individualization_steps = 0:0.01:1

# =========================
# Mixed allocation across individualization steps
# =========================
mixed_allocation_df = DataFrame(step = collect(individualization_steps))
for client in clients
    flat = allocation_costs[socialized_allocation][client]
    indiv = allocation_costs[individualized_allocation][client]
    mixed_allocation_df[!, client] = (1 .- mixed_allocation_df.step) .* flat .+ mixed_allocation_df.step .* indiv
end

# =========================
# Stability check (exact -- coalition_costs already covers the full power set)
# =========================
max_excess_by_step = Float64[]
for row in eachrow(mixed_allocation_df)
    step_allocation = Dict(client => row[client] for client in clients)
    max_excess_step = check_stability(step_allocation, coalition_costs, clients)
    push!(max_excess_by_step, max_excess_step)
    println("Max excess for mixed allocation (step = ", row[:step], "): ", max_excess_step)
end

negative_excess_step = nothing
for (i, excess) in enumerate(max_excess_by_step)
    if excess < 0
        global negative_excess_step = individualization_steps[i]
        println("First individualization step where max excess is negative: ", negative_excess_step)
        break
    end
end
if isnothing(negative_excess_step)
    println("Max excess never becomes negative in the analyzed range")
end

# =========================
# Cost per MWh demand
# =========================
total_demand_by_client = Dict(client => sum(system_data["price_prod_demand_df"][!, client]) for client in clients)
mixed_allocation_cost_per_mwh_df = DataFrame(step = mixed_allocation_df.step)
for client in clients
    denom = total_demand_by_client[client]
    if isnothing(denom) || denom == 0
        mixed_allocation_cost_per_mwh_df[!, client] = fill(missing, nrow(mixed_allocation_df))
    else
        mixed_allocation_cost_per_mwh_df[!, client] = mixed_allocation_df[!, client] ./ denom
    end
end

# Flip sign to go from the negative-is-cost convention to positive-for-display
mixed_allocation_cost_per_mwh_df_plot = copy(mixed_allocation_cost_per_mwh_df)
for client in clients
    mixed_allocation_cost_per_mwh_df_plot[!, client] = -mixed_allocation_cost_per_mwh_df[!, client]
end

# =========================
# Export
# =========================
out_dir = joinpath(@__DIR__, "..", "..", "results", "cache_py", "socialized_vs_individualized")
mkpath(out_dir)
CSV.write(joinpath(out_dir, "mixed_allocation_cost_per_mwh.csv"), mixed_allocation_cost_per_mwh_df_plot)
write(joinpath(out_dir, "meta.json"), JSON.json(Dict(
    "clients" => clients,
    "negative_excess_step" => negative_excess_step,
)))
println("Exported socialized-vs-individualized results to ", out_dir)
