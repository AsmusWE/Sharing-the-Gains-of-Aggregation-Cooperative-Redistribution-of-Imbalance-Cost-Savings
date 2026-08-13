include("common_setup.jl")

using DataFrames, CSV, Dates

plotted_allocations = [
    "shapley",
    #"MCC",
    #"MCC_budget_balanced",
    #"VCG",
    "gately",
    #"gately_interval",
    "marginal_price", # Uniform price for cost
    #"reduced_cost",
    #"nucleolus",
    "flat_rate",
    #"scaled"
]

allocation_labels = Dict(
    "shapley" => ("Shapley", PALETTE_LIGHT_GREEN),
    "MCC" => ("MCC", :black),
    "MCC_budget_balanced" => ("MCC Budget Balanced", :orange),
    "VCG" => ("VCG", :purple),
    "gately" => ("Gately Point", PALETTE_SAND),
    "gately_interval" => ("Gately 15Min interval", :lightgrey),
    "marginal_price" => ("Marginal Price", PALETTE_ORANGE),
    "reduced_cost" => ("Asymmetric Price", :blue),
    "nucleolus" => ("Nucleolus", :green),
    "flat_rate" => ("Flat Rate", PALETTE_RED)
)

plot_data = deserialize(joinpath(@__DIR__, "..", "results", "cache", "22ClientMonthly.jls"))

wmape = Dict{String, Float64}()
for client in plot_data.clients
    wmape[client] = calculate_wmape(plot_data.coalition_imbalances, plot_data.system_data, client)
end

# Sort clients by total demand (highest to lowest)
clients_sorted = sort_clients_by_demand(plot_data.system_data, plot_data.clients)
# Use the struct for plotting
allocations = plot_data.allocations
allocations = filter(x -> x in plotted_allocations, allocations)
plot_results(
    allocations,
    plot_data.system_data,
    plot_data.allocation_costs,
    plot_data.coalition_costs,
    clients_sorted,
    plot_data.start_hour,
    plot_data.sim_days,
    allocation_labels,
    wmape
)

plot_cost_difference(
    plot_data.allocation_costs,
    clients_sorted,
    plot_data.system_data
)

# Printing max excess for each allocation method
for alloc in plot_data.allocations
    max_excess = check_stability(plot_data.allocation_costs[alloc], plot_data.coalition_costs, clients_sorted)
    println("Max excess for allocation method ", alloc, ": ", max_excess)
end
