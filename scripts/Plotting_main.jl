include("../src/Plotting_functions.jl")
include("../src/Imbalance_functions.jl")
include("../src/Types.jl")

using DataFrames, CSV, Dates

plottedAllocations = [
    "shapley",
    #"VCG",
    #"VCG_budget_balanced",
    "gately",
    #"gately_interval",
    "full_cost", # Uniform price for cost
    #"reduced_cost",
    #"nucleolus",
    "flat_rate",
    #"scaled"
]

LightGreen = RGB(150/255, 206/255, 180/255)
Sand = RGB(255/255, 238/255, 173/255)
Red = RGB(255/255, 111/255, 105/255)
Orange = RGB(255/255, 204/255, 92/255)
Green = RGB(136/255, 216/255, 176/255)

allocation_labels = Dict(
    "shapley" => ("Shapley", LightGreen),
    "VCG" => ("VCG", :black),
    "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
    "gately" => ("Gately Point", Sand),
    "gately_interval" => ("Gately 15Min interval", :lightgrey),
    "full_cost" => ("Marginal Price", Orange),
    "reduced_cost" => ("Asymmetric Price", :blue),
    "nucleolus" => ("Nucleolus", :green),
    "flat_rate" => ("Flat Rate", Red)
)

plotData = deserialize(joinpath(@__DIR__, "..", "results", "cache", "17ClientWeekly.jls"))

WMAPE = Dict{String, Float64}()
for client in plotData.clients
    WMAPE[client] = calculate_WMAPE(plotData.imbalancesDict, plotData.systemData, client)
end

# Sort clients by total demand (highest to lowest)
total_demands = Dict(client => sum(plotData.systemData["price_prod_demand_df"][!, Symbol(client)]) for client in plotData.clients)
sorted_clients_pairs = sort(collect(total_demands), by = x -> -x[2])  # Sort by demand descending
clients_sorted = [client for (client, _) in sorted_clients_pairs]
# Use the struct for plotting
allocations = plotData.allocations
allocations = filter(x -> x in plottedAllocations && x != "gately_interval", allocations)
plot_results(
    allocations,
    plotData.systemData,
    plotData.allocationCosts,
    plotData.coalitionCosts,
    clients_sorted,
    plotData.start_hour,
    plotData.sim_days,
    allocation_labels,
    WMAPE
)

plot_cost_difference(
    plotData.allocationCosts,
    clients_sorted,
    plotData.systemData
)

# Printing max excess for each allocation method
for alloc in plotData.allocations
    max_excess = check_stability(plotData.allocationCosts[alloc], plotData.coalitionCosts, clients_sorted)
    println("Max excess for allocation method ", alloc, ": ", max_excess)
end

