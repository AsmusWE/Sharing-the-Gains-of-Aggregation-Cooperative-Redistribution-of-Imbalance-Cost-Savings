# Imbalance_main.jl
# Main script for running coalition imbalance and allocation analysis
# Author: Asmus Winther Eriksen

# --- Project Modules ---
include("Data_import.jl")
include("Scenario_creation.jl")
include("imbalance_functions.jl")
include("Game_theoretic_functions.jl")
include("Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization #,StatsPlots
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# Define a struct to hold all relevant plotting data
struct SimplePlotData
    allocations::Vector{String}
    systemData::Dict{String, Any}
    allocationCosts::Dict{String, Any}
    coalitionCosts::Dict{Any, Any}
    imbalancesDict::Dict{Any, Any}
    clients::Vector{String}
    start_hour::DateTime
    sim_days::Int
end

# =========================
# 1. Data Loading & Setup
# =========================
# Choose which calculations to run
FileName = "17ClientWeekly.jls"


# Choose which allocations to calculate
allocations = [
    "shapley",
    "VCG",
    #"VCG_budget_balanced",
    #"gately",
    "gately_interval",
    "full_cost", # Uniform price for cost
    #"reduced_cost",
    #"nucleolus",
    "flat_rate",
    #"cost_based" # Uniform price for CVaR,
    #"scaled"
]


systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
#clients = filter(x -> !(x in ["X", "W", "N"]), clients)
clients = filter(x -> !(x in ["X", "W"]), clients)
# Filter down to 13 for nucleolus
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)
#clients = ["A","G","I","S","Y"]
#clients = ["A","G"]

start_hour = DateTime(2024, 01, 01, 00, 0, 0)
#sim_days = Int(floor((lastHour - start_hour) / Dates.Day(1))) # Calculate number of days from start_hour to lastHour
sim_days = 366
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 50 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
alphaCVaR = 0.95 # CVaR confidence level
beta = 0 # Weighting factor between cost and CVaR in total cost calculation
dailyPlot = false # Whether to run the daily calculations
dummy = false
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
# Remove allocation methods that are not suitable for cost+CVaR yet
#allocations = filter(x -> !(x in ["reduced_cost", "gately_interval"]), allocations)
# Remove allocation methods that do not work with the simple calculations 
#allocations = filter(x -> !(x in ["shapley", "nucleolus"]), allocations)
#coalitions = sparse_coalitions(clients)
coalitions = collect(combinations(clients)) # Full set of coalitions for simple plot
println("Calculating costs for simple plot...")

# Initialize accumulation dictionaries for weekly costs
accumulated_costsDict = Dict(coalition => 0.0 for coalition in coalitions)
accumulated_imbalancesDict = Dict(coalition => Float64[] for coalition in coalitions)

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
    weeklyTotalCostsDict, weeklyCostsDict, weeklyCvarDict, weeklyImbalancesDict = calculate_total_costs_specific(
        weekly_systemData, coalitions, stochasticData, days_in_week; alpha=alphaCVaR, beta = beta, dummy = dummy, onePrice = false, useNewsvendor = useNewsvendor
    )
    
    # Accumulate weekly results
    for coalition in coalitions
        accumulated_costsDict[coalition] += weeklyCostsDict[coalition]
        append!(accumulated_imbalancesDict[coalition], weeklyImbalancesDict[coalition])
    end
end

# Use accumulated results
costsDict = accumulated_costsDict
imbalancesDict = accumulated_imbalancesDict

allocation_costs = calculate_allocations(
    allocations, clients, costsDict, imbalancesDict, systemData; printing = false, alpha=alphaCVaR
)

#println("Total costs (regular + CVaR): ", totalCostsDict[clients])
println("Regular costs only: ", costsDict[clients])
#println("CVaR only: ", cvarDict[clients])

# Save cost+CVaR data for plotting 
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

#serialize("Results/" * FileName, plot_data)
serialize("C:\\Users\\s200583\\Downloads\\"* FileName, plot_data)

if dailyPlot
    allocations = filter(x -> x != "nucleolus", allocations)
    allocations = filter(x -> x != "cost_based", allocations)
    allocations = filter(x -> x != "shapley", allocations)

    println("Calculating allocations for daily plot...")

    GC.gc() # Run garbage collection to free memory before processing
    dailyCostAllocations, totalCostAllocations, totalImbalanceCosts, intervalImbalances, singletonCostsDaily = @time allocation_variance(allocations, clients, systemData, stochasticData, demandData, start_hour, sim_days)

    # Define a struct to hold variance plot data
    struct VariancePlotData
        allocations::Vector{String}
        totalCostAllocations::Dict{String, Any}
        dailyCostAllocations::Any
        totalImbalanceCosts::Dict{Any, Any}
        intervalImbalances::Any
        singletonCostsDaily::Any
        clients::Vector{String}
        sim_days::Int
    end

    # Create an instance of VariancePlotData
    variance_plot_data = VariancePlotData(
        allocations,
        totalCostAllocations,
        dailyCostAllocations,
        totalImbalanceCosts,
        intervalImbalances,
        singletonCostsDaily,
        clients,
        sim_days
    )
    println("Total singleton costs: ", sum(sum(singletonCostsDaily[client] for client in clients)))
    println("Total costs for all allocations: ", totalImbalanceCosts[clients])
    # Save variance plot data to the "Results" subfolder
    serialize("Results/" * dailyPlotFileName, variance_plot_data)

end
GC.gc() # Run garbage collection to free memory after processing

for allocation in allocations
    maxExcess = check_stability(allocation_costs[allocation], costsDict, clients)
    println("Max excess for ", allocation, ": ", maxExcess)
end

