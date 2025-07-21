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
using Plots, Dates, Random, Combinatorics, StatsPlots, Serialization, DataFrames, LsqFit
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
systemData, clients, demandData = load_data()
clients = filter(x -> x != "G", clients)
clients = filter(x -> !(x in ["W", "N", "V", "J"]), clients)
#clients = filter(x -> !(x in ["L", "U"]), clients)
coalitions = collect(combinations(clients))

start_hour = DateTime(2025, 3, 6, 12, 0, 0)
sim_days = 1
num_scenarios = 5

alpha = 0.05 # CVaR alpha level


# Accepted forecast types: "perfect", "scenarios", "noise"
systemData["demand_forecast"] = "scenarios"
systemData["pv_forecast"] = "scenarios"
# Set standard deviations for noise
# Adjusting so demand MAE is 7-10% and PV MAE is 22.5-25%
# Note: PV forecast gives MAE of 22.5-25% using scenarios
systemData["demand_noise_std"] = 0.17
systemData["pv_noise_std"] = 0.32

if systemData["demand_forecast"] == "scenarios"
    systemData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, sim_days; num_scenarios=num_scenarios)
end
if systemData["pv_forecast"] == "noise"
    systemData["pv_forecast_noise"] = generate_noise_forecast_PV(clients, systemData, start_hour, sim_days)
end

# Cut systemData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)


allocations = [
    "shapley",
    "VCG",
    #"VCG_budget_balanced",
    "gately",
    #"gately_daily",
    #"gately_interval",
    #"full_cost",
    #"reduced_cost",
    "nucleolus",
    #"equal_share",
    "cost_based"
]

# =========================
# 2. Imbalance Calculation and allocation
# =========================
timing_df = DataFrame(
    clients = Int16[],
    allocation = String[],
    CVaR_calc_time = Float64[],
    allocation_calc_time = Float64[]
)

# Do a first unsaved run to ensure the functions are compiled
CVaR_full_time = @elapsed coalitionCVaR, imbalances = calculate_CVaR(systemData, clients, start_hour, sim_days; printing=false, alpha=alpha)
CVaR_Gately_time = @elapsed _ = CVaR_Gately(systemData, clients, start_hour, sim_days; printing=false, alpha=alpha)
allocation_times = calculate_allocations(
allocations, clients, coalitions, coalitionCVaR, imbalances, systemData, alpha; printing = false, return_time = true
)

for i in 1:(length(clients)-1)
    current_clients = clients[i:end]
    println("Current clients: ", current_clients)
    # Time calculation time for each coalition size 
    CVaR_full_time = @elapsed coalitionCVaR, imbalances = calculate_CVaR(systemData, current_clients, start_hour, sim_days; printing=false, alpha=alpha)
    CVaR_Gately_time = @elapsed _ = CVaR_Gately(systemData, current_clients, start_hour, sim_days; printing=false, alpha=alpha)
    coalitions = collect(combinations(current_clients))
    allocation_times = calculate_allocations(
    allocations, current_clients, coalitions, coalitionCVaR, imbalances, systemData, alpha; printing = false, return_time = true
    )
    for allocation in allocations
        if allocation == "nucleolus" || allocation == "shapley"
            push!(timing_df, (length(current_clients), allocation, CVaR_full_time, allocation_times[allocation]))
        else
            push!(timing_df, (length(current_clients), allocation, CVaR_Gately_time, allocation_times[allocation]))
        end
    end
end

# Create the total_time column
timing_df.total_time = timing_df.CVaR_calc_time .+ timing_df.allocation_calc_time

# Create the plot
p = plot(
    xlabel = "Number of Clients",
    ylabel = "Computation Time (seconds)",
    title = "Computation Time for Allocations",
    legend = :topleft,
    xticks = 1:16,
    #xlims = (1, 16),
    yscale = :log10,
    #yticks = [10^0, 10^1, 10^2, 10^3, 10^4, 10^5]
)

# Plot the data
allocation_labels = Dict(
    "shapley" => ("Shapley", :red),
    "VCG" => ("VCG", :yellow),
    "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
    "gately" => ("Gately Point", :grey),
    #"gately_daily" => ("Gately Daily", :black),
    "gately_interval" => ("Gately 15Min interval", :lightgrey),
    "full_cost" => ("Full Cost", :pink),
    "reduced_cost" => ("Reduced Cost", :lightblue),
    "nucleolus" => ("Nucleolus", :green),
    "equal_share" => ("Equal Share", :purple),
    "cost_based" => ("Cost Based", :cyan)
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
savefig(p, "Results/timing_nucleolus.svg")
display(p)


