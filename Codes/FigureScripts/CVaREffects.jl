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
sim_days = 366
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
println("Number of clients: ", length(clients))

# Simulation parameters
num_scenarios_demand = 5
num_scenarios_price = 50
spread_scens_length = 1
alphaCVaR = 0.95  # CVaR confidence level
onePrice = false  # One-price (true) or two-price (false)
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

# Keep original demandData for scenario generation (needs historical data)
originalDemandData = deepcopy(demandData)

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
    
    results["regular_income"][coalition_name] = Float64[]
    results["cvar_income"][coalition_name] = Float64[]
end

println("\nCalculating income for different beta values...")
println("Beta values: ", collect(beta_values))

# Calculate costs for each beta value
for (beta_idx, beta) in enumerate(beta_values)
    println("\nProcessing beta = $beta ($(beta_idx)/$(length(beta_values)))")
    
    # Initialize accumulation dictionaries for weekly costs
    accumulated_totalIncomeDict = Dict(coalition => 0.0 for coalition in coalitions_to_analyze)
    accumulated_incomeDict = Dict(coalition => 0.0 for coalition in coalitions_to_analyze)
    accumulated_cvarDict = Dict(coalition => 0.0 for coalition in coalitions_to_analyze)
    accumulated_imbalancesDict = Dict(coalition => Float64[] for coalition in coalitions_to_analyze)
    
    # Optimize week by week (7 days at a time)
    week_length = 7
    num_weeks = Int(ceil(sim_days / week_length))
    
    for week in 1:num_weeks
        # Calculate the start day and length for this week
        week_start_day = (week - 1) * week_length + 1
        days_in_week = min(week_length, sim_days - week_start_day + 1)
        
        println("  Processing week $week of $num_weeks (days $week_start_day to $(week_start_day + days_in_week - 1))")
        
        # Create weekly system data
        current_week_start = start_hour + Dates.Day(week_start_day - 1)
        weekly_systemData = set_period!(deepcopy(systemData), current_week_start, days_in_week)
        
        # Generate demand scenarios for this specific week
        stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, originalDemandData, current_week_start, days_in_week; num_scenarios=num_scenarios_demand)
        
        # Calculate costs for this week
        weeklyTotalIncomeDict, weeklyIncomeDict, weeklyCvarDict, weeklyImbalancesDict = calculate_total_costs_specific(
            weekly_systemData, coalitions_to_analyze, stochasticData, days_in_week; alpha=alphaCVaR, beta = beta, onePrice = onePrice
        )
        
        # Accumulate weekly results
        for coalition in coalitions_to_analyze
            accumulated_totalIncomeDict[coalition] += weeklyTotalIncomeDict[coalition]
            accumulated_incomeDict[coalition] += weeklyIncomeDict[coalition]
            accumulated_cvarDict[coalition] += weeklyCvarDict[coalition]
            append!(accumulated_imbalancesDict[coalition], weeklyImbalancesDict[coalition])
        end
    end
    
    # Store accumulated results for each coalition
    for (i, coalition) in enumerate(coalitions_to_analyze)
        coalition_name = results["coalition_names"][i]
        
        # Use accumulated income and CVaR
        regular_income = accumulated_incomeDict[coalition]
        cvar_income = accumulated_cvarDict[coalition]
        
        push!(results["regular_income"][coalition_name], regular_income)
        push!(results["cvar_income"][coalition_name], cvar_income)
    end

    # Also calculate expected income and CVaR (regenerate full period scenarios first)
    println("Calculating expected income and CVaR for beta = $beta")
    # Regenerate demand scenarios for the full simulation period
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, originalDemandData, start_hour, sim_days; num_scenarios=num_scenarios_demand)
    bids, expected_income, expected_cvar = optimize_imbalance(clients, systemData, stochasticData; alpha=alphaCVaR, beta = beta, onePrice = onePrice, extendedOutput=true)
    
    # Store expected income and CVaR
    push!(results["expected_income"], expected_income)
    push!(results["expected_cvars"], expected_cvar)

end

# =========================
# 3. Analysis and Visualization
# =========================
# Create plots
gr() # Use GR backend for plotting

full_coalition_name = "Full_Coalition"

# Plot 4: Regular Income vs CVaR Income with Beta values as scatter points
p4 = scatter(title="Realized Income vs Realized 5% Tail Income", xlabel="Income", ylabel="5% tail Income")

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
p5 = scatter(title="Expected Income vs Expected 5% Tail Income", xlabel="Expected Income", ylabel="Expected 5% Tail Income")

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
