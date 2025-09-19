# This script solves the bidding problem and generates a figure showing the cost distribution across 15 minute realization


# Imbalance_main.jl
# Main script for running coalition imbalance and allocation analysis
# Author: Asmus Winther Eriksen

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

# =========================
# 1. Data Loading & Setup
# =========================
systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)
clients = ["A","G"]

start_hour = DateTime(2025, 4, 04, 00, 0, 0)
sim_days = 1 # Calculate number of days from start_hour to lastHour
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 12 # Number of scenarios for demand
num_scenarios_price = 100 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
alphaCVaR = 0.05 # CVaR confidence level
beta = 1 # Weighting factor between cost and CVaR in total cost calculation
dailyPlot = false # Whether to run the daily calculations

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

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)


# =========================
# 2. Imbalance Calculation and allocation
# =========================
coalitions = sparse_coalitions(clients)
println("Calculating total costs (regular costs + CVaR) for simple plot...")
totalCostsDict, costsDict, cvarDict, imbalancesDict = @time calculate_total_costs_specific(
    systemData, coalitions, stochasticData, sim_days; alpha=alphaCVaR, beta = beta
)


# --- Plot cost distribution of the grand coalition ---
T = sim_days * 96
imbalance_spread = systemData["price_prod_demand_df"][1:T, "ImbalanceSpreadEUR"]
grand_imbalances = imbalancesDict[grandCoalition]
grand_costs_timeseries = grand_imbalances .* imbalance_spread
grand_costs_timeseries = max.(0, grand_costs_timeseries) # Only consider positive costs for two price scheme

# Plot histogram
histogram(grand_costs_timeseries, bins=50, title="Grand Coalition Cost Distribution",
    xlabel="Cost per 15-min interval (EUR)", ylabel="Frequency", legend=false)




