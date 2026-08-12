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
FileName = "19ClientWeekly.jls"

allocations = ALLOCATION_PRESETS[:default]

systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
clients = filter(x -> !(x in CLIENT_EXCLUSION_PRESETS[:drop_smallest_3]), clients)

start_hour = DateTime(2024, 01, 01, 00, 0, 0)
#sim_days = Int(floor((lastHour - start_hour) / Dates.Day(1))) # Calculate number of days from start_hour to lastHour
sim_days = 366
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 50 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
dummy = false # Whether to do dummy bidding (bid expected net consumption) instead of optimizing
useNewsvendor = true # Whether to use newsvendor approach for imbalance cost calculation

stochasticData = Dict(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    "demand_noise_std" => 0.28,
)

if stochasticData["demand_forecast"] == "scenarios"
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

stochasticData["imbalance_spread"], stochasticData["spot_price"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Keep original demandData for scenario generation (needs historical data)
originalDemandData = deepcopy(demandData)

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)


# =========================
# 2. Imbalance Calculation and allocation
# =========================
coalitions = collect(combinations(clients)) # Full set of coalitions for simple plot
println("Calculating costs for simple plot...")

# Only retain coalitions that are needed for imbalance calculations (singletons, full coalition, and all coalitions missing one client)
neededImbalanceCoalitions = Set(vcat(
    [[c] for c in clients],
    [clients],
    [filter(x -> x != c, clients) for c in clients],
))

# Initialize accumulation dictionaries for weekly costs
accumulated_costsDict = Dict(coalition => 0.0 for coalition in coalitions)
accumulated_imbalancesDict = Dict(coalition => Float64[] for coalition in coalitions if coalition in neededImbalanceCoalitions)

# Optimize week by week (7 days at a time)
week_length = 30
num_weeks = Int(ceil(sim_days / week_length))

for week in 1:num_weeks
    GC.gc() # Run garbage collection to free memory before processing each week
    # Calculate the start day and length for this week
    week_start_day = (week - 1) * week_length + 1
    days_in_week = min(week_length, sim_days - week_start_day + 1)
    
    println("Processing week $week of $num_weeks (days $week_start_day to $(week_start_day + days_in_week - 1))")
    
    # Create weekly system data
    current_week_start = start_hour + Dates.Day(week_start_day - 1)
    weekly_systemData = set_period!(deepcopy(systemData), current_week_start, days_in_week)
    
    # Generate demand scenarios for this specific week
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, originalDemandData, current_week_start, days_in_week; num_scenarios=num_scenarios_demand)
    
    # Calculate costs for this week
    weeklyCostsDict, weeklyImbalancesDict = calculate_total_costs_specific(
        weekly_systemData, coalitions, stochasticData, days_in_week; dummy = dummy, onePrice = false, useNewsvendor = useNewsvendor
    )
    
    # Accumulate weekly results
    for coalition in coalitions
        accumulated_costsDict[coalition] += weeklyCostsDict[coalition]
        if coalition in neededImbalanceCoalitions
            append!(accumulated_imbalancesDict[coalition], weeklyImbalancesDict[coalition])
        end
    end
end

# Use accumulated results
costsDict = accumulated_costsDict
imbalancesDict = accumulated_imbalancesDict

allocation_costs = calculate_allocations(
    allocations, clients, costsDict, imbalancesDict, systemData; printing = false
)

println("Total costs: ", costsDict[clients])

# Save cost data for plotting
plot_data = SimplePlotData(
    allocations,
    systemData,
    allocation_costs,
    costsDict,
    imbalancesDict,
    clients,
    start_hour,
    sim_days
)

serialize(joinpath(@__DIR__, "..", "results", "cache", FileName), plot_data)

GC.gc() # Run garbage collection to free memory after processing

for allocation in allocations
    maxExcess = check_stability(allocation_costs[allocation], costsDict, clients)
    println("Max excess for ", allocation, ": ", maxExcess)
end

