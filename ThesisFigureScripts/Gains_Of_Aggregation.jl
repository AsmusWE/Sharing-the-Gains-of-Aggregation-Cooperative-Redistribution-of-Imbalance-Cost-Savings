

# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, StatsPlots, Serialization
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
#clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)

# Last hour 2025-07-20T03:45:00
start_hour = DateTime(2025, 4, 04, 00, 0, 0)
#start_hour = DateTime(2025, 3, 04, 12, 0, 0)
#start_hour = start_hour + Dates.Day(3) # Start at 00:00 of the next day
#sim_days = 50
sim_days = Int(floor((lastHour - start_hour) / Dates.Day(1)))-1 # Calculate number of days from start_hour to lastHour
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days - 1))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5
num_scenarios_price = 30 # Number of scenarios for imbalance spread
spread_scens_length = 96 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
chunkSize = 3 # Days processed at a time when calculating imbalance costs, adjust based on memory

stochasticData = Dict(
    # Accepted forecast types: "perfect", "scenarios", "noise"
    "pv_forecast" => "perfect",
    "demand_forecast" => "noise",
    # Set standard deviations in percent for noise
    # Adjusting so demand MAE is 7-10% and PV MAE is 22.5-25%
    # Note: PV forecast gives MAE of 22.5-25% using scenarios
    "demand_noise_std" => 0.28,
    "pv_noise_std" => 0.32
)

if stochasticData["demand_forecast"] == "scenarios"
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

if stochasticData["pv_forecast"] == "noise"
    stochasticData["pv_forecast_noise"] = generate_noise_forecast_PV(systemData, start_hour, sim_days)
end
stochasticData["imbalance_spread"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)


coalitions = sparse_coalitions(clients)

stdDevMax = 1
stdDevMin = 0
stepSize = 1 
steps = Int(floor((stdDevMax - stdDevMin) / stepSize)) + 1
println("Running with $steps steps from $stdDevMin to $stdDevMax")
singletonCostsSum = zeros(Float64,steps)
aggregatedCosts = zeros(Float64,steps)
for (i, stdDev) in enumerate(stdDevMin:stepSize:stdDevMax)
    stochasticData["demand_noise_std"] = stdDev
    #stochasticData["pv_noise_std"] = stdDev
    println("Running with demand noise std: $stdDev")
    
    coalitionCosts, imbalancesDict = @time calculate_costs_specific(
        systemData, coalitions, stochasticData, sim_days
    )
    for client in clients
        singletonCostsSum[i] += coalitionCosts[[client]]
    end
    aggregatedCosts[i] = coalitionCosts[clients]
end

costRatio = aggregatedCosts ./ singletonCostsSum
costRatio[1] = 1

stdDevRange = collect(stdDevMin:stepSize:stdDevMax)
plot(
    stdDevRange, costRatio,
    xlabel="Demand Noise Std Dev",
    ylabel="Singleton Cost Sum / Aggregated Cost",
    title="Cost Ratio vs Demand Noise Std Dev",
    legend=false,
    marker=:circle,
    linewidth=2
)

# Sort clients by total demand (highest to lowest)
total_demands = Dict(client => sum(systemData["price_prod_demand_df"][!, Symbol(client)]) for client in clients)
sorted_clients_pairs = sort(collect(total_demands), by = x -> -x[2])  # Sort by demand descending
clients = [client for (client, _) in sorted_clients_pairs]

stochasticData["demand_noise_std"] = 0.28
stochasticData["pv_forecast"] = "scenarios"
stochasticData["demand_forecast"] = "scenarios"
averageCostRatio = zeros(Float64, length(clients))
# Filter out smallest clients to be able to use imbalance_costs()
filtered_clients = filter(x -> !(x in ["X", "W", "N"]), clients)
#coalitionCosts, imbalances, imbalancesDict = @time imbalance_costs(systemData, filtered_clients, start_hour, sim_days, stochasticData; printing=true, chunkSize=chunkSize)
# Missing coalitions will be calculated using calculate_costs_specific

#loadedData = deserialize("../Results/all_scenarios.jls")
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
loadedData = deserialize("c:\\Users\\asmus\\OneDrive\\Dokumenter\\Uni\\Kandidat\\Speciale\\Git repository\\Control-and-revenue-distribution-of-shared-hybrid-PV-and-battery-systems\\Results\\all_scenarios.jls")
coalitionCosts = loadedData.imbalances
for i in 1:(length(filtered_clients))
    # Calculate the average cost ratio for coalitions of size i
    coalitions_of_size_i = [coalition for coalition in keys(coalitionCosts) if length(coalition) == i]
    cost_ratios_for_size_i = Float64[]
    for coalition in coalitions_of_size_i
        # Calculate sum of singleton costs for this coalition
        singleton_sum = sum(coalitionCosts[[client]] for client in coalition)
        # Calculate cost ratio
        cost_ratio = coalitionCosts[coalition] / singleton_sum 
        push!(cost_ratios_for_size_i, cost_ratio)
    end
    
    # Store the average cost ratio for coalitions of size i
    averageCostRatio[i] = sum(cost_ratios_for_size_i) / length(cost_ratios_for_size_i)
end


plot(
    1:(length(filtered_clients)), averageCostRatio[1:(length(filtered_clients))]*100,
    xlabel="Number of Clients in Coalition",
    ylabel="Cost Ratio [%]",
    xticks=1:(length(filtered_clients)),
    title="Cost Ratio vs Coalition Size",
    legend=false,
    marker=:circle,
    linewidth=2
)

