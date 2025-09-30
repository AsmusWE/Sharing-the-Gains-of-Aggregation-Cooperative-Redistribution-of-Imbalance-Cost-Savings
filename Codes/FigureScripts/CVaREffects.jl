# CVaREffects.jl
# This script runs through different values of beta for CVaR and calculates the imbalance income for the full aggregation and individual cases.
# Beta controls the weight between regular income (1-beta) and CVaR (beta) in the objective function
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
println("Analyzing the effect of different beta values on income and CVaR")

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

start_hour = DateTime(2024, 01, 01, 00, 0, 0)
sim_days = 28
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
    "total_income" => Dict(),
    "regular_income" => Dict(),
    "cvar_income" => Dict(),
    "coalition_names" => [],
    "expected_income" => Float64[],
    "expected_cvars" => Float64[]
)

# Create coalition names for results
for (i, coalition) in enumerate(coalitions_to_analyze)
    coalition_name = "Full_Coalition"
    push!(results["coalition_names"], coalition_name)
    
    results["total_income"][coalition_name] = Float64[]
    results["regular_income"][coalition_name] = Float64[]
    results["cvar_income"][coalition_name] = Float64[]
end

println("\nCalculating income for different beta values...")
println("Beta values: ", collect(beta_values))

# Calculate costs for each beta value
for (beta_idx, beta) in enumerate(beta_values)
    println("\nProcessing beta = $beta ($(beta_idx)/$(length(beta_values)))")
    
    # Calculate total income, regular income, and CVaR for current beta
    totalIncomeDict, incomeDict, cvarDict, imbalancesDict = calculate_total_costs_specific(
        systemData, coalitions_to_analyze, stochasticData, sim_days; alpha=alphaCVaR, beta = beta
    )
    
    # Store results for each coalition
    for (i, coalition) in enumerate(coalitions_to_analyze)
        coalition_name = results["coalition_names"][i]
        
        # Calculate weighted total income using current beta
        regular_income = incomeDict[coalition]
        cvar_income = cvarDict[coalition]
        total_income = regular_income + cvar_income
        
        push!(results["total_income"][coalition_name], total_income)
        push!(results["regular_income"][coalition_name], regular_income)
        push!(results["cvar_income"][coalition_name], cvar_income)
    end

    # Also calculate expected income and CVaR
    println("Calculating expected income and CVaR for beta = $beta")
    bids, expected_income, expected_cvar = optimize_imbalance(clients, systemData, stochasticData; alpha=alphaCVaR, beta = beta, extendedOutput=true)
    
    # Store expected income and CVaR
    push!(results["expected_income"], expected_income)
    push!(results["expected_cvars"], expected_cvar)

end

# =========================
# 3. Analysis and Visualization
# =========================

println("\n=== Results Summary ===")
coalition_name = "Full_Coalition"
println("\n$coalition_name:")
println("  Regular income: $(round(results["regular_income"][coalition_name][1], digits=2))")
println("  CVaR income: $(round(results["cvar_income"][coalition_name][1], digits=2))")
println("  Total income: $(round(results["total_income"][coalition_name][1], digits=2))")

# Create plots
gr() # Use GR backend for plotting

full_coalition_name = "Full_Coalition"

# Plot 4: Regular Income vs CVaR Income with Beta values as scatter points
p4 = scatter(title="Realized Total Income vs Realized 5% Tail Income", xlabel="Total Income", ylabel="5% tail Income")

# Plot regular points first
scatter!(p4, results["regular_income"][full_coalition_name], results["cvar_income"][full_coalition_name],
         marker=:circle, color=:purple, markersize=8, alpha=0.7,
         markerstrokecolor=:black, markerstrokewidth=1, legend = :false)

# Highlight beta = 0 and beta = 1 points with different colors
for (i, beta) in enumerate(results["beta_values"])
    if beta == 0.0
        # Highlight beta = 0 in red with larger marker
        scatter!(p4, [results["regular_income"][full_coalition_name][i]], [results["cvar_income"][full_coalition_name][i]],
                marker=:circle, color=:red, markersize=12, alpha=1.0,
                markerstrokecolor=:darkred, markerstrokewidth=2, legend = :false)
    elseif beta == 1.0
        # Highlight beta = 1 in blue with larger marker
        scatter!(p4, [results["regular_income"][full_coalition_name][i]], [results["cvar_income"][full_coalition_name][i]],
                marker=:circle, color=:blue, markersize=12, alpha=1.0,
                markerstrokecolor=:darkblue, markerstrokewidth=2, legend = :false)
    end
end

# Add text annotations for beta values
for (i, beta) in enumerate(results["beta_values"])
    annotate!(p4, results["regular_income"][full_coalition_name][i], 
              results["cvar_income"][full_coalition_name][i], 
              text("β=$(round(beta, digits=1))", 8, :center, :bottom), legend = :false)
end

# Plot 5: Expected Income vs Expected CVaR with Beta values as scatter points
p5 = scatter(title="Expected Total Income vs Expected 5% Tail Income", xlabel="Expected Total Income", ylabel="Expected 5% Tail Income")

# Plot regular points first
scatter!(p5, results["expected_income"], results["expected_cvars"],
         marker=:circle, color=:orange, markersize=8, alpha=0.7,
         markerstrokecolor=:black, markerstrokewidth=1, legend = :false)

# Add text annotations for beta values
for (i, beta) in enumerate(results["beta_values"])
    annotate!(p5, results["expected_income"][i], 
              results["expected_cvars"][i], 
              text("β=$(round(beta, digits=1))", 8, :center, :bottom), legend = :false)
end

# Display all plots
#display(p1)
#display(p2)
#display(p3)
display(p4)
display(p5)
