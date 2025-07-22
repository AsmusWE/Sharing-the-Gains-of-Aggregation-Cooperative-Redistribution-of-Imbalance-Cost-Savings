# Imbalance_main.jl
# Main script for running coalition imbalance and allocation analysis
# Author: Asmus Winther Eriksen

# --- Project Modules ---
include("Data_import.jl")
include("Scenario_creation.jl")
include("imbalance_functions.jl")
include("Game_theoretic_functions.jl")
include("Plotting.jl")
include("Timing_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, StatsPlots, Serialization
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
systemData, clients, demandData = load_data()
clients = filter(x -> x != "G", clients)
#clients = filter(x -> !(x in ["W", "N", "V", "J"]), clients)
#clients = filter(x -> !(x in ["L", "U"]), clients)
coalitions = collect(combinations(clients))

# First hour 2024-03-04T12:00:00
# Last hour 2025-04-26T03:45:00
start_hour = DateTime(2025, 4, 05, 0, 0, 0)
#start_hour = DateTime(2025, 3, 04, 12, 0, 0)
#start_hour = start_hour + Dates.Day(3) # Start at 00:00 of the next day
#sim_days = 50
sim_days = 20
num_scenarios_demand = 5
num_scenarios_price = 30 # Number of scenarios for imbalance spread
time_horizon = 1 * 96 # Sets the chunk size for the simulation and the length of the imbalance spread scenarios
alpha = 0.05 # CVaR alpha level

stochasticData = Dict(
    # Accepted forecast types: "perfect", "scenarios", "noise"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations for noise
    # Adjusting so demand MAE is 7-10% and PV MAE is 22.5-25%
    # Note: PV forecast gives MAE of 22.5-25% using scenarios
    "demand_noise_std" => 0.17,
    "pv_noise_std" => 0.32
)

if stochasticData["demand_forecast"] == "scenarios"
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

if stochasticData["pv_forecast"] == "noise"
    stochasticData["pv_forecast_noise"] = generate_noise_forecast_PV(systemData, start_hour, sim_days)
end
stochasticData["imbalance_spread"] = generate_scenarios_imbalance_spread(systemData, start_hour, time_horizon; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)

allocations = [
    "shapley",
    "VCG",
    #"VCG_budget_balanced",
    "gately",
    #"gately_daily",
    "gately_interval",
    "full_cost",
    "reduced_cost",
    #nucleolus",
    #"equal_share",
    "flat_rate"
]

# =========================
# 2. Imbalance Calculation and allocation
# =========================
# Calculating costs
println("Calculating imbalance costs...")
coalitionCosts, imbalances, imbalancesDict = @time imbalance_costs(systemData, clients, start_hour, sim_days, stochasticData; printing=false, chunkSize=time_horizon)

# Checking MAE
#MAE_demand, MAE_pv = calculate_MAE(systemData, demandForecast, pvForecast, clients, start_hour, sim_days)
#println("MAE Demand: ", MAE_demand)
#println("MAE PV: ", MAE_pv)

# Calculating allocations
println("Calculating allocations...")
#daily_cost_MWh_imbalance, allocation_costs, imbalances, hourly_imbalances = @time allocation_variance(allocations, clients, coalitions, systemData, start_hour, sim_days)

allocation_costs = calculate_allocations(
    allocations, clients, coalitions, coalitionCosts, imbalances, imbalancesDict, systemData, demandData; printing = true
    )

# Checking stability
max_instability = Dict{String, Float64}()
for alloc in allocations
    println("Checking stability for allocation: ", alloc)
    max_instability[alloc] = check_stability(allocation_costs[alloc], coalitionCosts, clients)
end
println("Max instabilities: ", max_instability)

# Compare the sum of individual client CVaR with the grand coalition CVaR
grand_coalition = clients
grand_coalition_Cost = coalitionCosts[grand_coalition]

individual_Cost_sum = sum(coalitionCosts[[client]] for client in clients)
VCG_cost = sum(values(allocation_costs["VCG"]))

println("Grand coalition Cost: ", grand_coalition_Cost)
println("Sum of individual client Cost: ", individual_Cost_sum)
#println("Difference: ", grand_coalition_imbalance - individual_imbalance_sum)
println("VCG cost: ", VCG_cost)
println("VCG subsidies: ", grand_coalition_Cost - VCG_cost)

# Define a struct to hold all relevant plotting data
struct PlotData
    allocations::Vector{String}
    systemData::Dict{String, Any}
    allocation_costs::Dict{String, Any}
    imbalances::Dict{Any, Any}
    clients::Vector{String}
    start_hour::DateTime
    sim_days::Int
    daily_cost_MWh_imbalance::Any
end

# Create an instance of PlotData
plot_data = PlotData(
    allocations,
    systemData,
    allocation_costs,
    coalitionCosts,
    clients,
    start_hour,
    sim_days,
    0 # Placeholder for daily_cost_MWh_imbalance, as it is not calculated in this script
)
# Save plot_data to the "Results" subfolder
serialize("Results/temp.jls", plot_data)

# Use the struct for plotting
plot_results(
    plot_data.allocations,
    plot_data.systemData,
    plot_data.allocation_costs,
    plot_data.imbalances,
    plot_data.clients,
    plot_data.start_hour,
    plot_data.sim_days
)


println("Calculating allocations for daily plot...")
daily_cost_MWh_imbalance, allocation_costs, imbalances, hourly_imbalances = @time allocation_variance(allocations, clients, systemData, stochasticData, start_hour, sim_days)

plotClient = "V"
plot_variance(
    allocations,
    allocation_costs,
    daily_cost_MWh_imbalance,
    imbalances,
    plotClient,
    sim_days;
    outliers = false
)



GC.gc() # Run garbage collection to free memory after processing


