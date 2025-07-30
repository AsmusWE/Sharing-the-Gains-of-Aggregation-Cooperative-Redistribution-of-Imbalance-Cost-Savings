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
    totalCosts::Dict{String, Any}
    dailyCost::Any
    totalImbalances::Dict{Any, Any}
    intervalImbalances::Any
    clients::Vector{String}
    sim_days::Int
end

#plotData = deserialize("Results/all_scens.jls")
plotData = deserialize("Results/all_scens_temp.jls")

# Use the struct for plotting
plot_results(
    plotData.allocations,
    plotData.systemData,
    plotData.allocation_costs,
    plotData.imbalances,
    plotData.clients,
    plotData.start_hour,
    plotData.sim_days
)

plotDataVariance = deserialize("Results/variance_plot_data_scens_temp.jls")
plotclient = "A"
plot_variance(
    plotDataVariance.allocations,
    plotDataVariance.dailyCost,
    plotclient,
    plotDataVariance.sim_days;
    outliers = false
)
