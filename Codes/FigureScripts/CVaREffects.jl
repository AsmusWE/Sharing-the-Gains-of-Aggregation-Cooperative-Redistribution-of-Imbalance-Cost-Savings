# CVaREffects.jl
# This script runs through different values of beta for CVaR and calculates the imbalance costs for the full aggregation and individual cases.
# Beta controls the weight between regular costs (1-beta) and CVaR (beta) in the objective function
# Author: Asmus Winther Eriksen

# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../Imbalance_functions.jl")
include("../Game_theoretic_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization, DataFrames, Statistics
GC.gc() # Run garbage collection to free memory

Random.seed!(1) # Set seed for reproducibility

println("=== CVaR Effects Analysis ===")
println("Analyzing the effect of different beta values on costs and CVaR")

# =========================
# 1. Data Loading & Setup
# =========================

systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])

# Filter clients for computational efficiency
#clients = filter(x -> !(x in ["X", "W", "N"]), clients)  # Remove smallest clients
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)  # Further filter to 12 clients
#clients = ["A","G"]

start_hour = DateTime(2024, 07, 01, 00, 0, 0)
sim_days = 30
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
println("Number of clients: ", length(clients))

# Simulation parameters
num_scenarios_demand = 5
num_scenarios_price = 50
spread_scens_length = 1
alphaCVaR = 0.95  # CVaR confidence level
beta_values = vcat([0.001], collect(0.1:0.1:1))  # Add 0.001 as the first value
# Setup stochastic data
stochasticData = Dict(
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    "demand_noise_std" => 0.28,
)

if stochasticData["demand_forecast"] == "scenarios"
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

stochasticData["imbalance_spread"], stochasticData["spot_price"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)

# =========================
# 2. CVaR Analysis for Different Beta Values
# =========================

# Define coalitions to analyze
coalitions_to_analyze = [
    clients        # Full coalition (all clients)
]

# Initialize results storage
results = Dict(
    "beta_values" => collect(beta_values),
    "total_costs" => Dict(),
    "regular_costs" => Dict(),
    "cvar_costs" => Dict(),
    "coalition_names" => [],
    "expected_costs" => Float64[],
    "expected_cvars" => Float64[]
)

# Create coalition names for results
for (i, coalition) in enumerate(coalitions_to_analyze)
    coalition_name = "Full_Coalition"
    push!(results["coalition_names"], coalition_name)
    
    results["total_costs"][coalition_name] = Float64[]
    results["regular_costs"][coalition_name] = Float64[]
    results["cvar_costs"][coalition_name] = Float64[]
end

println("\nCalculating costs for different beta values...")
println("Beta values: ", collect(beta_values))

# Calculate costs for each beta value
for (beta_idx, beta) in enumerate(beta_values)
    println("\nProcessing beta = $beta ($(beta_idx)/$(length(beta_values)))")
    
    # Calculate total costs, regular costs, and CVaR for current beta
    totalCostsDict, costsDict, cvarDict, imbalancesDict = calculate_total_costs_specific(
        systemData, coalitions_to_analyze, stochasticData, sim_days; alpha=alphaCVaR, beta = beta
    )
    
    # Store results for each coalition
    for (i, coalition) in enumerate(coalitions_to_analyze)
        coalition_name = results["coalition_names"][i]
        
        # Calculate weighted total cost using current beta
        regular_cost = costsDict[coalition]
        cvar_cost = cvarDict[coalition]
        total_cost = regular_cost + cvar_cost
        
        push!(results["total_costs"][coalition_name], total_cost)
        push!(results["regular_costs"][coalition_name], regular_cost)
        push!(results["cvar_costs"][coalition_name], cvar_cost)
    end

    # Also calculate expected cost and CVaR
    println("Calculating expected cost and CVaR for beta = $beta")
    bids, expected_cost, expected_cvar = optimize_imbalance(clients, systemData, stochasticData; alpha=alphaCVaR, beta = beta, extendedOutput=true)
    
    # Store expected cost and CVaR
    push!(results["expected_costs"], expected_cost)
    push!(results["expected_cvars"], expected_cvar)

end

# =========================
# 3. Analysis and Visualization
# =========================

println("\n=== Results Summary ===")
coalition_name = "Full_Coalition"
println("\n$coalition_name:")
println("  Regular cost: $(round(results["regular_costs"][coalition_name][1], digits=2))")
println("  CVaR cost: $(round(results["cvar_costs"][coalition_name][1], digits=2))")
println("  Total cost: $(round(results["total_costs"][coalition_name][1], digits=2))")

# Create plots
gr() # Use GR backend for plotting

full_coalition_name = "Full_Coalition"

# Plot 1: Regular Cost vs Beta
p1 = plot(title="Regular Cost vs Beta", xlabel="Beta (CVaR weight)", ylabel="Regular Cost")
plot!(p1, results["beta_values"], results["regular_costs"][full_coalition_name], 
      linewidth=3, marker=:circle, color=:blue, markersize=6)

# Plot 2: CVaR Cost vs Beta  
p2 = plot(title="CVaR Cost vs Beta", xlabel="Beta (CVaR weight)", ylabel="CVaR Cost")
plot!(p2, results["beta_values"], results["cvar_costs"][full_coalition_name], 
      linewidth=3, marker=:square, color=:red, markersize=6)

# Plot 3: Total Cost vs Beta
p3 = plot(title="Total Cost vs Beta", xlabel="Beta (CVaR weight)", ylabel="Total Cost")
plot!(p3, results["beta_values"], results["total_costs"][full_coalition_name], 
      linewidth=3, marker=:diamond, color=:green, markersize=6)

# Plot 4: Regular Cost vs CVaR Cost with Beta values as scatter points
p4 = scatter(title="Realized Total Cost vs Realized 5% Tail Cost", xlabel="Total Cost", ylabel="5% tail Cost")

# Plot regular points first
scatter!(p4, results["regular_costs"][full_coalition_name], results["cvar_costs"][full_coalition_name],
         marker=:circle, color=:purple, markersize=8, alpha=0.7,
         markerstrokecolor=:black, markerstrokewidth=1, legend = :false)

# Highlight beta = 0 and beta = 1 points with different colors
for (i, beta) in enumerate(results["beta_values"])
    if beta == 0.0
        # Highlight beta = 0 in red with larger marker
        scatter!(p4, [results["regular_costs"][full_coalition_name][i]], [results["cvar_costs"][full_coalition_name][i]],
                marker=:circle, color=:red, markersize=12, alpha=1.0,
                markerstrokecolor=:darkred, markerstrokewidth=2, legend = :false)
    elseif beta == 1.0
        # Highlight beta = 1 in blue with larger marker
        scatter!(p4, [results["regular_costs"][full_coalition_name][i]], [results["cvar_costs"][full_coalition_name][i]],
                marker=:circle, color=:blue, markersize=12, alpha=1.0,
                markerstrokecolor=:darkblue, markerstrokewidth=2, legend = :false)
    end
end

# Add text annotations for beta values
for (i, beta) in enumerate(results["beta_values"])
    annotate!(p4, results["regular_costs"][full_coalition_name][i], 
              results["cvar_costs"][full_coalition_name][i], 
              text("β=$(round(beta, digits=1))", 8, :center, :bottom), legend = :false)
end

# Plot 5: Expected Cost vs Expected CVaR with Beta values as scatter points
p5 = scatter(title="Expected Total Cost vs Expected 5% Tail Cost", xlabel="Expected Total Cost", ylabel="Expected 5% Tail Cost")

# Plot regular points first
scatter!(p5, results["expected_costs"], results["expected_cvars"],
         marker=:circle, color=:orange, markersize=8, alpha=0.7,
         markerstrokecolor=:black, markerstrokewidth=1, legend = :false)

# Highlight beta = 0 and beta = 1 points with different colors
for (i, beta) in enumerate(results["beta_values"])
    if beta == 0.0
        # Highlight beta = 0 in red with larger marker
        scatter!(p5, [results["expected_costs"][i]], [results["expected_cvars"][i]],
                marker=:circle, color=:red, markersize=12, alpha=1.0,
                markerstrokecolor=:darkred, markerstrokewidth=2, legend = :false)
    elseif beta == 1.0
        # Highlight beta = 1 in blue with larger marker
        scatter!(p5, [results["expected_costs"][i]], [results["expected_cvars"][i]],
                marker=:circle, color=:blue, markersize=12, alpha=1.0,
                markerstrokecolor=:darkblue, markerstrokewidth=2, legend = :false)
    end
end

# Add text annotations for beta values
for (i, beta) in enumerate(results["beta_values"])
    annotate!(p5, results["expected_costs"][i], 
              results["expected_cvars"][i], 
              text("β=$(round(beta, digits=1))", 8, :center, :bottom), legend = :false)
end

# Display all plots
#display(p1)
#display(p2)
#display(p3)
display(p4)
display(p5)
