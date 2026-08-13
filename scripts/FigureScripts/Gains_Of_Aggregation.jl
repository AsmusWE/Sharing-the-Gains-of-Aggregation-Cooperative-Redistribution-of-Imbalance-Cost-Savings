

# --- Project Modules ---
include("../common_setup.jl")

# --- External Packages ---
using Plots, Dates, Combinatorics, Serialization
GC.gc() # Run garbage collection to free memory, useful for repeat runs

plot_data = deserialize(joinpath(@__DIR__, "..", "..", "results", "cache", "17ClientWeekly.jls"))

# =========================
# 1. Load data from serialized file
# =========================
println("Loading data from serialized file")

# Extract clients and coalition costs directly from plot_data
clients = plot_data.clients
coalition_costs = plot_data.coalition_costs

println("Number of clients: ", length(clients))
println("Number of coalitions: ", length(coalition_costs))

# average_cost_ratio[i] = unweighted average cost ratio for coalitions of size i (not per-client)
average_cost_ratio = zeros(Float64, length(clients))

# Store all individual cost ratios for plotting
all_cost_ratios = Dict{Int, Vector{Float64}}()

for i in 1:(length(clients))
    # Calculate the unweighted average cost ratio for coalitions of size i
    coalitions_of_size_i = [coalition for coalition in keys(coalition_costs) if length(coalition) == i]
    cost_ratios = Float64[]

    for coalition in coalitions_of_size_i
        # Calculate cost ratio for this coalition
        coalition_cost = coalition_costs[coalition]
        singleton_sum = sum(coalition_costs[[client]] for client in coalition)
        push!(cost_ratios, coalition_cost / singleton_sum)
    end

    # Store all cost ratios for this coalition size
    all_cost_ratios[i] = cost_ratios

    # Store the unweighted average cost ratio for coalitions of size i
    average_cost_ratio[i] = mean(cost_ratios)
end

# First, create plot with filled area showing range of coalition costs
p = plot(; xlabel="Number of Clients in Coalition",
         ylabel="Relative cost [%]",
         xticks=1:(length(clients)),
         xrotation = 45,
         #legend=:topright,
         SMALL_FIGURE_STYLE...,
         xguidefont=font(8, "Times Roman"),
         legendfontsize=6)

# Calculate min and max for each coalition size to create filled area
x_vals = Int[]
min_vals = Float64[]
max_vals = Float64[]

for i in 1:(length(clients))
    if haskey(all_cost_ratios, i) && !isempty(all_cost_ratios[i])
        push!(x_vals, i)
        push!(min_vals, minimum(all_cost_ratios[i]) * 100)
        push!(max_vals, maximum(all_cost_ratios[i]) * 100)
    end
end

# Create filled area by plotting upper and lower bounds
plot!(p, x_vals, min_vals,
      fillrange=max_vals,
      fillalpha=0.8,
      fillcolor=PALETTE_SAND,
      linewidth=0,
      color=:transparent,
      label="Relative cost range")

# Then add the averaged values on top
plot!(p, 1:(length(clients)), average_cost_ratio[1:(length(clients))]*100,
      marker=:circle,
      markersize=3,
      linewidth=2,
      color=PALETTE_LIGHT_GREEN,
      label="Unweighted average")

display(p)
savefig(p, "Gains_of_Aggregation_17Clients_New.png")
