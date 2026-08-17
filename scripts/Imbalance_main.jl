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
file_name = "AllClientMonthly.jls"

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

stochastic_data = Dict(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    "demand_noise_std" => 0.28,
)

if stochastic_data["demand_forecast"] == "scenarios"
    stochastic_data["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demand_data, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

stochastic_data["imbalance_spread"], stochastic_data["spot_price"] = generate_scenarios_imbalance_spread(system_data, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochastic_data["dominant_direction_scenarios"] = generate_dominant_direction(stochastic_data["imbalance_spread"])

# Keep original demand_data for scenario generation (needs historical data)
original_demand_data = deepcopy(demand_data)

# Cut system_data and demand_data to the simulation period
system_data = set_period(system_data, start_hour, sim_days)
demand_data = set_period(demand_data, start_hour, sim_days)


# =========================
# 2. Imbalance Calculation and allocation
# =========================
coalitions = collect(combinations(clients)) # Full set of coalitions for simple plot
println("Calculating costs for simple plot...")
flush(stdout)

# Only retain coalitions that are needed for imbalance calculations (singletons, full coalition, and all coalitions missing one client)
needed_imbalance_coalitions = Set(vcat(
    [[c] for c in clients],
    [clients],
    [filter(x -> x != c, clients) for c in clients],
))

# Initialize accumulation dictionaries across reconciliation periods
accumulated_coalition_costs = Dict(coalition => 0.0 for coalition in coalitions)
accumulated_coalition_imbalances = Dict(coalition => Float64[] for coalition in coalitions if coalition in needed_imbalance_coalitions)

# Optimize in reconciliation periods (30 days at a time)
reconciliation_period_days = 30
num_periods = Int(ceil(sim_days / reconciliation_period_days))

for period in 1:num_periods
    GC.gc() # Run garbage collection to free memory before processing each period
    # Calculate the start day and length for this period
    period_start_day = (period - 1) * reconciliation_period_days + 1
    days_in_period = min(reconciliation_period_days, sim_days - period_start_day + 1)

    println("Processing period $period of $num_periods (days $period_start_day to $(period_start_day + days_in_period - 1))")
    flush(stdout)

    # Create system data for this period
    period_start = start_hour + Dates.Day(period_start_day - 1)
    period_system_data = set_period(deepcopy(system_data), period_start, days_in_period)

    # Generate demand scenarios for this specific period
    stochastic_data["demand_scenarios"] = generate_scenarios_demand_rolling(clients, original_demand_data, period_start, days_in_period; num_scenarios=num_scenarios_demand)

    # Calculate costs for this period
    period_coalition_costs, period_coalition_imbalances = calculate_total_costs_specific(
        period_system_data, coalitions, stochastic_data, days_in_period; dummy = dummy, one_price = false, use_newsvendor = use_newsvendor
    )

    # Accumulate results for this period
    for coalition in coalitions
        accumulated_coalition_costs[coalition] += period_coalition_costs[coalition]
        if coalition in needed_imbalance_coalitions
            append!(accumulated_coalition_imbalances[coalition], period_coalition_imbalances[coalition])
        end
    end
end

# Use accumulated results
coalition_costs = accumulated_coalition_costs
coalition_imbalances = accumulated_coalition_imbalances

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
