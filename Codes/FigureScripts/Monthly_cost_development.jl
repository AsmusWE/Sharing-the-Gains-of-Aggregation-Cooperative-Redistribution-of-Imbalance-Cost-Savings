# This code simulates monthly costs and plots the cost to the BRP and clients
# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../Imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

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
# Choose filename of saved data
FileName = "temp.jls"

# Choose which allocations to calculate
allocations = [
    #"shapley",
    "VCG",
    #"VCG_budget_balanced",
    "gately",
    #"gately_interval",
    #"full_cost", # Uniform price for cost
    #"reduced_cost",
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
clients = ["A","G"]

start_hour = DateTime(2025, 4, 04, 00, 0, 0)
simulation_months = 3
month_length = 30 # Days in a month

num_scenarios_demand = 12 # Number of scenarios for demand
num_scenarios_price = 100 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
alphaCVaR = 0.05 # CVaR confidence level
beta = 0 # Weighting factor between cost and CVaR in total cost calculation
dailyPlot = false # Whether to run the daily calculations

stochasticData = Dict(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    "demand_noise_std" => 0.28,
)

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, simulation_months*month_length)


# =========================
# 2. Imbalance Calculation and allocation
# =========================
# Remove allocation methods that are not suitable for cost+CVaR yet
allocations = filter(x -> !(x in ["full_cost", "reduced_cost", "gately_interval"]), allocations)
# Remove allocation methods that do not work with the simple calculations 
allocations = filter(x -> !(x in ["shapley", "nucleolus"]), allocations)
coalitions = sparse_coalitions(clients)
println("Calculating total costs (regular costs + CVaR) for simple plot...")
monthlyClientImbalanceCosts = Dict()
monthlyClientCVaRCosts = Dict()
for month in 1:simulation_months
    println("Calculating month ", month, " of ", simulation_months)
    monthData = set_period!(systemData, start_hour + Dates.Day((month-1)*month_length), month_length)
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, simulation_months*month_length; num_scenarios=num_scenarios_demand)
    stochasticData["imbalance_spread"], stochasticData["spot_price"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
    stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])
    #monthDataStochastic = set_period!(stochasticData, start_hour + Dates.Day((month-1)*month_length), month_length)
    sim_days = month_length
    totalCostsDict, costsDict, cvarDict, imbalancesDict = @time calculate_total_costs_specific(
        monthData, coalitions, stochasticData, sim_days; alpha=alphaCVaR, beta = beta
    )

    allocation_costs = calculate_allocations(
        allocations, clients, totalCostsDict, imbalancesDict, monthData; printing = true, alpha=alphaCVaR
    )

end
