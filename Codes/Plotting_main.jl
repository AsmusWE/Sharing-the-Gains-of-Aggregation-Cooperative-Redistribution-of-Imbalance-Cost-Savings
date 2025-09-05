include("Plotting_functions.jl")
include("Imbalance_functions.jl")

using DataFrames, CSV, Dates

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

allocation_labels = Dict(
    "shapley" => ("Shapley", :red),
    "VCG" => ("VCG", :purple),
    "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
    "gately" => ("Gately Point", :black),
    "gately_interval" => ("Gately 15Min interval", :lightgrey),
    "full_cost" => ("Uniform Price", :red),
    "reduced_cost" => ("Asymmetric Price", :blue),
    "nucleolus" => ("Nucleolus", :green),
    "cost_based" => ("Uniform Price", :red),
    "flat_rate" => ("Flat Rate", :cyan)
)

plotData = deserialize("Results/simpleScenResults.jls")
#plotData = deserialize("Results/simple_plot_perfectPV_scenDemand.jls")
#plotData = deserialize("Results/simple_plot_perfectPV_noiseDemand.jls")
#plotData = deserialize("Results/CVaR_scenPV_scenDemand.jls")
WMAPE = deserialize("Results/demandScenPVScen_WMAPE.jls")


# Sort clients by total demand (highest to lowest)
total_demands = Dict(client => sum(plotData.systemData["price_prod_demand_df"][!, Symbol(client)]) for client in plotData.clients)
sorted_clients_pairs = sort(collect(total_demands), by = x -> -x[2])  # Sort by demand descending
clients_sorted = [client for (client, _) in sorted_clients_pairs]
# Use the struct for plotting
plot_results(
    plotData.allocations,
    plotData.systemData,
    plotData.allocationCosts,
    plotData.coalitionCosts,
    clients_sorted,
    plotData.start_hour,
    plotData.sim_days,
    allocation_labels,
    WMAPE;
    cvar = false
)

plot_cost_difference(
    plotData.allocationCosts,
    clients_sorted,
    plotData.systemData
)

if false
plotDataVariance = deserialize("Results/variance_plot_data_scenDemand_scenPV.jls")
plotclient = "P"

plot_variance(
    plotDataVariance.allocations,
    plotDataVariance.dailyCostAllocations,
    plotDataVariance.singletonCostsDaily,
    plotclient,
    plotDataVariance.sim_days,
    allocation_labels;
    outliers = true
)
end