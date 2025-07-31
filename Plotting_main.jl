include("Plotting_functions.jl")

using DataFrames, CSV, Dates


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
    totalCost::Dict{String, Any}
    dailyCost::Any
    totalImbalances::Dict{Any, Any}
    intervalImbalances::Any
    clients::Vector{String}
    sim_days::Int
end
allocation_labels = Dict(
        "shapley" => ("Shapley", :red),
        "VCG" => ("VCG", :yellow),
        "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
        "gately" => ("Gately Daily", :grey),
        #"gately_daily" => ("Gately Daily", :black),
        "gately_interval" => ("Gately 15Min", :lightgrey),
        "full_cost" => ("Full Cost", :pink),
        "reduced_cost" => ("Reduced Cost", :lightblue),
        "nucleolus" => ("Nucleolus", :green),
        "equal_share" => ("Equal Share", :purple),
        #"cost_based" => ("Cost Based", :cyan),
        "flat_rate" => ("Flat Rate", :cyan)
    )

#plotData = deserialize("Results/all_scens.jls")
#plotData = deserialize("Results/all_perfectPV.jls")
#plotData = deserialize("Results/all_scens_temp.jls")
plotData = deserialize("Results/all_noiseDemand_perfectPV.jls")

# Sort clients by total demand (highest to lowest)
total_demands = Dict(client => sum(plotData.systemData["price_prod_demand_df"][!, Symbol(client)]) for client in plotData.clients)
sorted_clients_pairs = sort(collect(total_demands), by = x -> -x[2])  # Sort by demand descending
clients_sorted = [client for (client, _) in sorted_clients_pairs]

# Use the struct for plotting
plot_results(
    plotData.allocations,
    plotData.systemData,
    plotData.allocation_costs,
    plotData.imbalances,
    clients_sorted,
    plotData.start_hour,
    plotData.sim_days,
    allocation_labels
)

plot_cost_difference(
    plotData.allocation_costs,
    clients_sorted,
    plotData.systemData
)

plotDataVariance = deserialize("Results/variance_plot_data_scens_temp.jls")
plotclient = "A"
#plot_variance(
#    plotDataVariance.allocations,
#    plotDataVariance.dailyCost,
#    plotclient,
#    plotDataVariance.sim_days,
#    allocation_labels;
#    outliers = false
#)

