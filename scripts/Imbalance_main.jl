# Imbalance_main.jl
# Main script for running coalition imbalance and allocation analysis
# Author: Asmus Winther Eriksen

# --- Project Modules ---
include("common_setup.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization #,StatsPlots
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
# Choose which calculations to run
file_name = "AllClientMonthly2.jls"

allocations = ALLOCATION_PRESETS[:default]

system_data, clients, demand_data = load_data()
first_hour = minimum(system_data["price_prod_demand_df"][!, :HourUTC_datetime])
last_hour = maximum(system_data["price_prod_demand_df"][!, :HourUTC_datetime])
clients = filter(x -> !(x in CLIENT_EXCLUSION_PRESETS[:none]), clients)

start_hour = DateTime(2024, 01, 01, 00, 0, 0)
#sim_days = Int(floor((last_hour - start_hour) / Dates.Day(1))) # Calculate number of days from start_hour to last_hour
sim_days = 366
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
flush(stdout)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 50 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
dummy = false # Whether to do dummy bidding (bid expected net consumption) instead of optimizing
use_newsvendor = true # Whether to use newsvendor approach for imbalance cost calculation

stochastic_data = Dict{String, Any}(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    #"demand_noise_std" => 0.28,
)

if stochastic_data["demand_forecast"] == "scenarios"
    stochastic_data["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demand_data, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

stochastic_data["imbalance_spread"], stochastic_data["spot_price"] = generate_scenarios_imbalance_spread(system_data, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochastic_data["dominant_direction_scenarios"] = generate_dominant_direction(stochastic_data["imbalance_spread"])

# Cut system_data and demand_data to the simulation period
system_data = set_period(system_data, start_hour, sim_days)
demand_data = set_period(demand_data, start_hour, sim_days)


# =========================
# 2. Imbalance Calculation and allocation
# =========================
coalitions = collect(combinations(clients)) # Full set of coalitions for simple plot

# Only retain coalitions that are needed for imbalance calculations (singletons, full coalition, and all coalitions missing one client)
needed_imbalance_coalitions = Set(vcat(
    [[c] for c in clients],
    [clients],
    [filter(x -> x != c, clients) for c in clients],
))

# Batch over coalitions, not time, to bound memory. calculate_total_costs_specific holds every
# requested coalition's full-year imbalance timeseries in memory at once, and the full power set
# (2^|clients| - 1 coalitions) at full-year hourly resolution doesn't fit all at once. Batching
# by coalition instead of by time avoids the DST-drift bug the previous 30-day reconciliation
# chunking had (see TestTheoreticalResults.jl for the diagnosis): system_data/stochastic_data
# are sliced to the full year exactly once, up front, and every batch reuses that same slice
# unchanged -- there is no per-batch re-slicing of the time axis for results to drift out of
# sync against. calculate_bids computes a multi-client coalition's bid as the sum of its
# members' independently-computed singleton bids (no shared state across coalitions), so
# batching the coalition list doesn't change the numbers, only the peak memory.
coalition_batch_size = 40_000
num_batches = Int(ceil(length(coalitions) / coalition_batch_size))
coalition_costs = Dict{Any, Float64}()
coalition_imbalances = Dict{Any, Vector{Float64}}()

for (batch_idx, batch_start) in enumerate(1:coalition_batch_size:length(coalitions))
    GC.gc() # Run garbage collection to free memory before processing each batch
    batch_end = min(batch_start + coalition_batch_size - 1, length(coalitions))
    batch = coalitions[batch_start:batch_end]

    println("Calculating costs for coalition batch $batch_idx of $num_batches ($(length(batch)) coalitions)")
    flush(stdout)

    batch_costs, batch_imbalances = calculate_total_costs_specific(
        system_data, batch, stochastic_data, sim_days; dummy = dummy, one_price = false, use_newsvendor = use_newsvendor
    )

    merge!(coalition_costs, batch_costs)
    for coalition in batch
        if coalition in needed_imbalance_coalitions
            coalition_imbalances[coalition] = batch_imbalances[coalition]
        end
    end
end

allocation_costs = calculate_allocations(
    allocations, clients, coalition_costs, coalition_imbalances, system_data; printing = false
)

println("Total costs: ", coalition_costs[clients])
flush(stdout)

# Save cost data for plotting
plot_data = SimplePlotData(
    allocations,
    system_data,
    allocation_costs,
    coalition_costs,
    coalition_imbalances,
    clients,
    start_hour,
    sim_days
)

serialize(joinpath(@__DIR__, "..", "results", "cache", file_name), plot_data)

GC.gc() # Run garbage collection to free memory after processing

for allocation in allocations
    max_excess = check_stability(allocation_costs[allocation], coalition_costs, clients)
    println("Max excess for ", allocation, ": ", max_excess)
    flush(stdout)
end
