# Timing_script.jl
# Main script for running coalition imbalance and allocation analysis timing
# Author: Asmus Winther Eriksen

# --- Project Modules ---
include("Data_import.jl")
include("Scenario_creation.jl")
include("imbalance_functions.jl")
include("Game_theoretic_functions.jl")
include("Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, StatsPlots, Serialization, DataFrames, LsqFit
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
systemData, clients, demandData = load_data()
# Filter out smallest clients if using nucleolus
clients = filter(x -> !(x in ["X", "W", "N","F", "V", "J", "P", "M", "D"]), clients)
#clients = filter(x -> !(x in ["X", "W", "N","F", "V", "J"]), clients)
coalitions = collect(combinations(clients))

start_hour = DateTime(2025, 3, 6, 12, 0, 0)
sim_days = 1
num_scenarios = 5

# Accepted forecast types: "perfect", "scenarios", "noise"
demand_forecast = "scenarios"
pv_forecast = "scenarios"
# Set standard deviations for noise
# Adjusting so demand MAE is 7-10% and PV MAE is 22.5-25%
# Note: PV forecast gives MAE of 22.5-25% using scenarios
demand_noise_std = 0.17
pv_noise_std = 0.32

# Create stochasticData dictionary
stochasticData = Dict(
    "demand_forecast" => demand_forecast,
    "pv_forecast" => pv_forecast,
    "demand_noise_std" => demand_noise_std,
    "pv_noise_std" => pv_noise_std
)

if demand_forecast == "scenarios"
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, sim_days; num_scenarios=num_scenarios)
end
if pv_forecast == "noise"
    stochasticData["pv_forecast_noise"] = generate_noise_forecast_PV(clients, systemData, start_hour, sim_days)
end

# Generate imbalance spread scenarios and dominant direction
stochasticData["imbalance_spread"] = generate_scenarios_imbalance_spread(systemData, start_hour, sim_days*24; num_scenarios=num_scenarios)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Cut systemData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)

allocations = [
    "shapley",
    "VCG",
    "VCG_budget_balanced",
    "gately",
    #"gately_daily",
    "gately_interval",
    "full_cost",
    "reduced_cost",
    "nucleolus",
    #"equal_share",
    #"cost_based",
    #"flat_rate"
]

# =========================
# 2. Imbalance Calculation and allocation
# =========================
timing_df = DataFrame(
    clients = Int16[],
    allocation = String[],
    costs_calc_time = Float64[],
    allocation_calc_time = Float64[]
)

# Do a first unsaved run to ensure the functions are compiled
# Use a local scope to avoid polluting the global namespace
println("Running initial unsaved timing run...")
let
    coalitionCosts, imbalances, imbalancesDict = imbalance_costs(systemData, clients, start_hour, sim_days, stochasticData; printing=false)
    costs_Gately(systemData, clients, sim_days, stochasticData; printing=false)
    calculate_allocations(
        allocations, clients, coalitions, coalitionCosts, imbalances, imbalancesDict, systemData, demandData; printing = false, return_time = true
    )
end

for i in 1:(length(clients)-1)
    current_clients = clients[i:end]
    println("Current clients: ", current_clients)
    # Generate coalitions for the current client subset
    current_coalitions = collect(combinations(current_clients))
    println("  Number of coalitions: $(length(current_coalitions))")
    
    # Time calculation time for different amounts of coalitions
    costs_full_time = @elapsed coalitionCosts, imbalances, imbalancesDict = imbalance_costs(systemData, current_clients, start_hour, sim_days, stochasticData; printing=false)
    costs_Gately(systemData, clients, sim_days, stochasticData; printing=false)
    costs_Gately_time = @elapsed costs_Gately(systemData, current_clients, sim_days, stochasticData; printing=false)
    
    
    println("  Calculating allocations...")
    allocation_times = calculate_allocations(
        allocations, current_clients, current_coalitions, coalitionCosts, imbalances, imbalancesDict, systemData, demandData; printing = false, return_time = true
    )
    for allocation in allocations
        if allocation == "nucleolus" || allocation == "shapley"
            push!(timing_df, (length(current_clients), allocation, costs_full_time, allocation_times[allocation]))
        else
            push!(timing_df, (length(current_clients), allocation, costs_Gately_time, allocation_times[allocation]))
        end
    end
    GC.gc()
end

# Create the total_time column
timing_df.total_time = timing_df.costs_calc_time .+ timing_df.allocation_calc_time

# Create the plot
p = plot(
    xlabel = "Number of Clients",
    ylabel = "Computation Time (seconds)",
    title = "Computation Time for Allocations",
    legend = :topleft,
    xticks = 1:22,
    #xlims = (1, 16),
    #yscale = :log10,
    #yticks = [10^0, 10^1, 10^2, 10^3, 10^4, 10^5]
)

# Plot the data
allocation_labels = Dict(
    "shapley" => ("Shapley", :red),
    "VCG" => ("VCG", :darkblue),
    "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
    "gately" => ("Gately Point", :grey),
    #"gately_daily" => ("Gately Daily", :black),
    "gately_interval" => ("Gately 15Min interval", :lightgrey),
    "full_cost" => ("Uniform Price", :pink),
    "reduced_cost" => ("Reduced Cost", :yellow),
    "nucleolus" => ("Nucleolus", :green),
    #"equal_share" => ("Equal Share", :purple),
    #"cost_based" => ("Cost Based", :cyan),
    "flat_rate" => ("Flat Rate", :cyan)
)

unique_allocations = unique(timing_df.allocation)
for allocation in unique_allocations
    alloc_data = filter(row -> row.allocation == allocation, timing_df)
    if nrow(alloc_data) > 0
        label, color = allocation_labels[allocation]
        plot!(p, alloc_data.clients, alloc_data.total_time, 
              label=label, color=color, linewidth=2, marker=:circle)
    end
end

# Save and display the plot
savefig(p, "Results/timing_all22svg")
display(p)


