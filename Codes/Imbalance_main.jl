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
FileName = "temp.jls"


# Choose which allocations to calculate
allocations = [
    #"shapley",
    #"VCG",
    #"VCG_budget_balanced",
    "gately",
    #"gately_interval",
    "full_cost", # Uniform price for cost
    "reduced_cost",
    #"nucleolus",
    #"flat_rate",
    #"cost_based" # Uniform price for CVaR
]


systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)

start_hour = DateTime(2025, 4, 04, 00, 0, 0)
sim_days = Int(floor((lastHour - start_hour) / Dates.Day(1)))-1 # Calculate number of days from start_hour to lastHour
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days - 1))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 30 # Number of scenarios for imbalance spread
spread_scens_length = 96 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
chunkSize = 3 # Days processed at a time when calculating imbalance costs in the full coalition calculations, adjust based on memory
alphaCVaR = 0.025 # CVaR confidence level

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

stochasticData["imbalance_spread"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)


# =========================
# 2. Imbalance Calculation and allocation
# =========================
# Remove allocation methods that are not suitable for cost+CVaR yet
allocations = filter(x -> !(x in ["full_cost", "reduced_cost", "gately_interval"]), allocations)
# Remove allocation methods that do not work with the simple calculations 
allocations = filter(x -> !(x in ["shapley", "nucleolus"]), allocations)
coalitions = sparse_coalitions(clients)
println("Calculating total costs (regular costs + CVaR) for simple plot...")
totalCostsDict, costsDict, cvarDict, imbalancesDict = @time calculate_total_costs_specific(
    systemData, coalitions, stochasticData, sim_days; alpha=alphaCVaR
)

allocation_costs = calculate_allocations(
    allocations, clients, totalCostsDict, imbalancesDict, systemData; printing = true, alpha=alphaCVaR
)

println("Total costs (regular + CVaR): ", totalCostsDict[clients])
println("Regular costs only: ", costsDict[clients])
println("CVaR only: ", cvarDict[clients])

# Save cost+CVaR data for plotting 
cost_cvar_plot_data = SimplePlotData(
    allocations,
    systemData,
    allocation_costs,
    totalCostsDict,
    imbalancesDict,
    clients,
    start_hour,
    sim_days
)

serialize("Results/" * FileName, cost_cvar_plot_data)

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


