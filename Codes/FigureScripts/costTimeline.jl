# This plot shows the aggregated vs unaggregated income over time for the two-price scheme

# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../Imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization, DataFrames, Printf
GC.gc() # Run garbage collection to free memory

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================

# Load system data
systemData, clients, demandData = load_data()

# Filter clients for manageable computation
#clients = filter(x -> !(x in ["A","G"]), clients)
#clients = filter(x -> !(x in ["X", "W", "N"]), clients)
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)
#clients = ["A","G","I","S","Q"]  # Select 5 clients for clear visualization

# Simulation parameters
start_hour = DateTime(2024, 01, 01, 00, 0, 0)
sim_days = 100  # One year for long timeframe (with 1-hour intervals: 8760 rows / 24 intervals per day = 365 days)
num_scenarios_demand = 5
num_scenarios_price = 50  # Reduce to require less historical data
spread_scens_length = 1
alphaCVaR = 0.025
onePrice = true  # Use two-price system
scale_equal = false # Whether to scale all clients to similar size
# Side-effect of scaling: Pv production not scaled, makes it insignificant for small clients

# PV Forecast Configuration - Switch between "perfect" and "scenarios"
pv_forecast_type = "scenarios"  # Options: "perfect" (uses actual SolarMWh), "scenarios" (uses PVForecast)
demand_forecast_type = "scenarios"  # Options: "perfect", "scenarios"

if scale_equal
    scale_equal!(systemData)
end
# Define different scenarios to compare
scenarios = [
    (beta=0.0, dummy=false, name="Income Only (β=0)", description="Optimize for imbalance income only"),
    (beta=1.0, dummy=false, name="CVaR Only (β=1)", description="Optimize for CVaR (risk) only"), 
    (beta=0.5, dummy=true, name="Dummy Bidding", description="Simple mean-based bidding strategy")
]

# =========================
# Client Selection for Income Timeline Comparison
# =========================

# Choose which client to compare against the grand coalition
selected_client = "G"  # Change this to any client you want to analyze

# Ensure the selected client is in the clients list for the income timeline comparison
if !(selected_client in clients)
    error("Client '$(selected_client)' not found in clients list. Available clients: $(clients)")
end

println("Selected client for income timeline comparison: $(selected_client)")
println("Available clients: $(join(clients, ", "))")

# Configure stochastic data - use the parameters defined above
stochasticData = Dict(
    "pv_forecast" => pv_forecast_type,
    "demand_forecast" => demand_forecast_type, 
    "demand_noise_std" => 0.28,
)

# Calculate intervals per day (1-hour intervals)
intervals_per_day = 24  # 1-hour intervals

# Check available data and adjust simulation period if necessary
available_rows = nrow(systemData["price_prod_demand_df"])
max_possible_days = div(available_rows, intervals_per_day)
sim_days = min(sim_days, max_possible_days)

println("Available data rows: $available_rows")
println("Maximum possible simulation days: $max_possible_days")
println("Using simulation days: $sim_days")

# Generate scenarios using the full original dataset before trimming
println("Generating scenarios using full original dataset...")

# Use an earlier start time for scenario generation to have enough historical data
# This should provide enough data points before the scenario start time
scenario_start_hour = DateTime(2024, 01, 01, 00, 0, 0)  # Use 2024 data for scenario generation

# Generate imbalance price scenarios with the full original dataset
stochasticData["imbalance_spread"], stochasticData["spot_price"] = generate_scenarios_imbalance_spread(systemData, scenario_start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Now set the period for simulation after scenario generation
systemData = set_period!(systemData, start_hour, sim_days)

# =========================
# 2. Calculate Daily Income for All Scenarios
# =========================

println("Calculating daily income for aggregated and unaggregated scenarios...")

# Initialize storage for all scenarios
all_results = Dict()

# Calculate costs for each scenario
for (i, scenario) in enumerate(scenarios)
    println("\n" * "="^60)
    println("SCENARIO $i: $(scenario.name)")
    println("$(scenario.description)")
    println("Beta: $(scenario.beta), Dummy: $(scenario.dummy)")
    println("="^60)
    
    # Initialize storage for this scenario
    daily_aggregated_income = Float64[]
    daily_unaggregated_income = Float64[]
    daily_aggregated_imbalances = Float64[]
    daily_unaggregated_imbalances = Float64[]
    daily_dates = Date[]
    
    # Calculate income for each day
    for day in 1:sim_days
        println("Processing day $day of $sim_days for $(scenario.name)")
        
        # Create daily system data - similar to monthly approach in costDistribution.jl
        current_day = start_hour + Dates.Day(day - 1)
        daily_systemData = set_period!(deepcopy(systemData), current_day, 1)  # 1 day period
        
        # Generate demand scenarios for this specific day
        stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, current_day, 1; num_scenarios=num_scenarios_demand)
        
        # Create coalitions for this calculation
        coalitions = sparse_coalitions(clients)
        
        # Calculate income for this day
        totalCostsDict, dailyCosts, cvarDict, imbalancesDict = calculate_total_costs_specific(
            daily_systemData, coalitions, stochasticData, 1; 
            alpha=alphaCVaR, beta=scenario.beta, dummy=scenario.dummy, onePrice=onePrice
        )
        
        # Use only regular imbalance income (dailyCosts represents income when negative)
        # This ensures we're comparing pure imbalance income without CVaR components
        aggregated_income = dailyCosts[clients]
        unaggregated_income = sum(dailyCosts[[client]] for client in clients)
        
        # Calculate imbalance volumes (absolute values for aggregation comparison)
        aggregated_imbalance_volume = sum(abs.(imbalancesDict[clients]))
        unaggregated_imbalance_volume = sum(sum(abs.(imbalancesDict[[client]])) for client in clients)
        
        # Store results
        push!(daily_aggregated_income, aggregated_income)
        push!(daily_unaggregated_income, unaggregated_income)
        push!(daily_aggregated_imbalances, aggregated_imbalance_volume)
        push!(daily_unaggregated_imbalances, unaggregated_imbalance_volume)
        push!(daily_dates, Date(current_day))
    end
    
    # Store results for this scenario
    all_results[scenario.name] = Dict(
        "aggregated" => daily_aggregated_income,
        "unaggregated" => daily_unaggregated_income,
        "aggregated_imbalances" => daily_aggregated_imbalances,
        "unaggregated_imbalances" => daily_unaggregated_imbalances,
        "dates" => daily_dates,
        "beta" => scenario.beta,
        "dummy" => scenario.dummy,
        "description" => scenario.description
    )
end

# =========================
# 2B. Calculate Selected Client vs Grand Coalition Income Timeline for Dummy Bidding
# =========================

println("\n" * "="^60)
println("CALCULATING CLIENT $(selected_client) vs GRAND COALITION INCOME TIMELINE")
println("="^60)

# Find the dummy bidding scenario
dummy_scenario = findfirst(s -> s.dummy == true, scenarios)
if dummy_scenario === nothing
    error("No dummy bidding scenario found!")
end

scenario = scenarios[dummy_scenario]
println("Using scenario: $(scenario.name) - $(scenario.description)")

# Initialize storage for selected client and grand coalition income timelines
daily_selected_client_income = Float64[]
daily_grand_coalition_income = Float64[]
daily_dates_income = Date[]

# Calculate daily income for selected client vs grand coalition under dummy bidding
for day in 1:sim_days
    println("Processing day $day of $sim_days for income timeline")
    
    # Create daily system data
    current_day = start_hour + Dates.Day(day - 1)
    daily_systemData = set_period!(deepcopy(systemData), current_day, 1)  # 1 day period
    
    # Generate demand scenarios for this specific day
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, current_day, 1; num_scenarios=num_scenarios_demand)
    
    # Create coalitions for this calculation (need both singleton selected client and grand coalition)
    coalitions = [[selected_client], clients]  # Selected client alone and grand coalition
    
    # Calculate income for this day using dummy bidding
    totalCostsDict, dailyCosts, cvarDict, imbalancesDict = calculate_total_costs_specific(
        daily_systemData, coalitions, stochasticData, 1; 
        alpha=alphaCVaR, beta=scenario.beta, dummy=scenario.dummy, onePrice=onePrice
    )
    
    # Extract income (dailyCosts represents income when negative, cost when positive)
    selected_client_income = dailyCosts[[selected_client]]
    grand_coalition_income = dailyCosts[clients]
    
    # Store results
    push!(daily_selected_client_income, selected_client_income)
    push!(daily_grand_coalition_income, grand_coalition_income)
    push!(daily_dates_income, Date(current_day))
end

# Calculate cumulative income
cumulative_selected_client_income = cumsum(daily_selected_client_income)
cumulative_grand_coalition_income = cumsum(daily_grand_coalition_income)

# Scale both sets of values to end up with income of 1 if positive or -1 if negative
final_selected_client_income = cumulative_selected_client_income[end]
final_grand_coalition_income = cumulative_grand_coalition_income[end]

if final_selected_client_income != 0
    scale_factor_client = (final_selected_client_income > 0 ? 1.0 : -1.0) / final_selected_client_income
    cumulative_selected_client_income = cumulative_selected_client_income .* scale_factor_client
end

if final_grand_coalition_income != 0
    scale_factor_coalition = (final_grand_coalition_income > 0 ? 1.0 : -1.0) / final_grand_coalition_income
    cumulative_grand_coalition_income = cumulative_grand_coalition_income .* scale_factor_coalition
end

println("Creating Client $(selected_client) vs Grand Coalition Income Timeline plot...")

# Create the income timeline comparison plot
p_income = plot(
    title="Income Timeline: Client $(selected_client) vs Grand Coalition (Dummy Bidding)\n$(scenario.description)",
    xlabel="Date",
    ylabel="Cumulative Income (EUR)",
    legend=:topleft,
    size=(1200, 700),
    grid=true,
    margins=5Plots.mm,
    linewidth=3,
    titlefontsize=12
)

# Plot selected client income timeline
plot!(p_income, daily_dates_income, cumulative_selected_client_income,
      label="Client $(selected_client) Income",
      color=:blue,
      linewidth=4,
      alpha=0.8)

# Plot grand coalition income timeline  
plot!(p_income, daily_dates_income, cumulative_grand_coalition_income,
      label="Grand Coalition Income",
      color=:red,
      linewidth=4,
      alpha=0.8)

# Calculate and display income statistics
total_selected_client_income = sum(daily_selected_client_income)
total_grand_coalition_income = sum(daily_grand_coalition_income)
avg_daily_selected_client_income = total_selected_client_income / sim_days
avg_daily_grand_coalition_income = total_grand_coalition_income / sim_days

# Add text annotation with income information
annotate!(p_income, daily_dates_income[div(sim_days, 4)], max(maximum(cumulative_selected_client_income), maximum(cumulative_grand_coalition_income)) * 0.85,
         text("Final Client $(selected_client) Income: €$(round(cumulative_selected_client_income[end], digits=2))\nFinal Grand Coalition Income: €$(round(cumulative_grand_coalition_income[end], digits=2))\nDaily Avg Client $(selected_client): €$(round(avg_daily_selected_client_income, digits=2))\nDaily Avg Grand Coalition: €$(round(avg_daily_grand_coalition_income, digits=2))", 
              10, :left, :black))

# Format x-axis for better date display
plot!(p_income, xrotation=45)

# Display the income timeline plot
display(p_income)

# Print summary statistics
println("\n" * "="^60)
println("CLIENT $(selected_client) vs GRAND COALITION INCOME SUMMARY")
println("="^60)
println("Simulation period: $(daily_dates_income[1]) to $(daily_dates_income[end])")
println("Number of days: $sim_days")
println()
println("CLIENT $(selected_client) INCOME:")
println("  Total income: €$(round(total_selected_client_income, digits=2))")
println("  Average daily income: €$(round(avg_daily_selected_client_income, digits=2))")
println("  Final cumulative income: €$(round(cumulative_selected_client_income[end], digits=2))")
println()
println("GRAND COALITION INCOME:")
println("  Total income: €$(round(total_grand_coalition_income, digits=2))")
println("  Average daily income: €$(round(avg_daily_grand_coalition_income, digits=2))")
println("  Final cumulative income: €$(round(cumulative_grand_coalition_income[end], digits=2))")
println()
println("COMPARISON:")
income_difference = total_grand_coalition_income - total_selected_client_income
income_ratio = total_grand_coalition_income / total_selected_client_income
println("  Grand Coalition income advantage: €$(round(income_difference, digits=2))")
println("  Income ratio (Grand Coalition / Client $(selected_client)): $(round(income_ratio, digits=2))")
println("="^60)

# =========================
# 3. Create Timeline Plots for Each Scenario
# =========================

println("\nCreating cumulative cost timeline plots for all scenarios...")

# Initialize array to store all plots
plots = []

# Create a plot for each scenario
for (scenario_name, results) in all_results
    println("Creating plot for: $scenario_name")
    
    # Extract results for this scenario
    daily_aggregated_income = results["aggregated"]
    daily_unaggregated_income = results["unaggregated"]
    daily_dates = results["dates"]
    
    # Calculate cumulative income
    cumulative_aggregated_income = cumsum(daily_aggregated_income)
    cumulative_unaggregated_income = cumsum(daily_unaggregated_income)
    # Calculate gains from aggregation (aggregated income should be higher)
    cumulative_gains = cumulative_aggregated_income .- cumulative_unaggregated_income
    
    # Create the plot for this scenario
    p = plot(
        title="$scenario_name\n$(results["description"])",
        xlabel="Date",
        ylabel="Cumulative Income (EUR)",
        legend=:topleft,
        size=(1000, 600),
        grid=true,
        margins=5Plots.mm,
        linewidth=2,
        titlefontsize=10
    )
    
    # Plot cumulative aggregated income (grand coalition)
    plot!(p, daily_dates, cumulative_aggregated_income,
          label="Aggregated Income (Coalition)",
          color=:blue,
          linewidth=3,
          alpha=0.8)
    
    # Plot cumulative unaggregated income (sum of individual income)
    plot!(p, daily_dates, cumulative_unaggregated_income,
          label="Unaggregated Income (Individual)",
          color=:red,
          linewidth=3,
          alpha=0.8)
    
    # Plot cumulative gains from aggregation
    plot!(p, daily_dates, cumulative_gains,
          label="Cumulative Gains from Aggregation",
          color=:green,
          linewidth=3,
          alpha=0.8,
          linestyle=:dash)
    
    # Calculate and display gains from aggregation
    total_gains = sum(daily_aggregated_income) - sum(daily_unaggregated_income)
    avg_daily_gains = total_gains / sim_days
    gains_percentage = (total_gains / sum(daily_unaggregated_income)) * 100
    final_cumulative_gains = cumulative_gains[end]
    
    # Add text annotation with gains information
    annotate!(p, daily_dates[div(sim_days, 4)], maximum(cumulative_aggregated_income) * 0.85,
             text("Final Gains: €$(round(final_cumulative_gains, digits=2))\nDaily Avg: €$(round(avg_daily_gains, digits=2))\nGains: $(round(gains_percentage, digits=1))%", 
                  9, :left, :black))
    
    # Format x-axis for better date display
    plot!(p, xrotation=45)
    
    # Display plot in separate figure window
    display(p)
    
    # Store statistics for summary
    results["total_gains"] = total_gains
    results["avg_daily_gains"] = avg_daily_gains
    results["gains_percentage"] = gains_percentage
    results["final_cumulative_gains"] = final_cumulative_gains
end

# Create a combined comparison plot showing gains from all scenarios
println("\nCreating combined comparison plot...")
p_comparison = plot(
    title="Cumulative Gains from Aggregation Comparison Across Bidding Strategies",
    xlabel="Date",
    ylabel="Cumulative Gains from Aggregation (EUR)",
    legend=:topleft,
    size=(1200, 600),
    grid=true,
    margins=5Plots.mm,
    linewidth=3
)

colors = [:blue, :red, :purple]
markers = [:circle, :square, :diamond]

for (i, (scenario_name, results)) in enumerate(all_results)
    daily_aggregated_income = results["aggregated"]
    daily_unaggregated_income = results["unaggregated"]
    cumulative_gains = cumsum(daily_aggregated_income) .- cumsum(daily_unaggregated_income)
    
    plot!(p_comparison, results["dates"], cumulative_gains,
          label=scenario_name,
          color=colors[i],
          marker=markers[i],
          markersize=2,
          alpha=0.8)
end

plot!(p_comparison, xrotation=45)

display(p_comparison)

# =========================
# 3B. Create Imbalance Volume Plots for Each Scenario
# =========================

println("\nCreating imbalance volume timeline plots for all scenarios...")

# Create imbalance volume plots for each scenario
for (scenario_name, results) in all_results
    println("Creating imbalance volume plot for: $scenario_name")
    
    # Extract imbalance volume results for this scenario
    daily_aggregated_imbalances = results["aggregated_imbalances"]
    daily_unaggregated_imbalances = results["unaggregated_imbalances"]
    daily_dates = results["dates"]
    
    # Calculate cumulative imbalance volumes
    cumulative_aggregated_imbalances = cumsum(daily_aggregated_imbalances)
    cumulative_unaggregated_imbalances = cumsum(daily_unaggregated_imbalances)
    cumulative_volume_reduction = cumulative_unaggregated_imbalances .- cumulative_aggregated_imbalances
    
    # Convert volume reduction to percentage
    cumulative_volume_reduction_percent = (cumulative_volume_reduction ./ cumulative_unaggregated_imbalances) .* 100
    
    # Create the imbalance volume plot for this scenario
    p_imbal = plot(
        title="Imbalance Volumes: $scenario_name\n$(results["description"])",
        xlabel="Date",
        ylabel="Volume Reduction from Aggregation (%)",
        legend=:topleft,
        size=(1000, 600),
        grid=true,
        margins=5Plots.mm,
        linewidth=2,
        titlefontsize=10
    )
    
    # Plot cumulative volume reduction as percentage
    plot!(p_imbal, daily_dates, cumulative_volume_reduction_percent,
          label="Volume Reduction from Aggregation (%)",
          color=:green,
          linewidth=3,
          alpha=0.8)
    
    # Calculate and display volume reduction statistics
    total_volume_reduction = sum(daily_unaggregated_imbalances) - sum(daily_aggregated_imbalances)
    avg_daily_volume_reduction = total_volume_reduction / sim_days
    volume_reduction_percentage = (total_volume_reduction / sum(daily_unaggregated_imbalances)) * 100
    final_cumulative_volume_reduction = cumulative_volume_reduction[end]
    
    # Add text annotation with volume reduction information
    final_cumulative_volume_reduction_percent = cumulative_volume_reduction_percent[end]
    annotate!(p_imbal, daily_dates[div(sim_days, 4)], maximum(cumulative_volume_reduction_percent) * 0.85,
             text("Final Volume Reduction: $(round(final_cumulative_volume_reduction_percent, digits=1))%\nAvg Daily Reduction: $(round(avg_daily_volume_reduction, digits=1)) MWh\nTotal Reduction: $(round(volume_reduction_percentage, digits=1))%", 
                  9, :left, :black))
    
    # Format x-axis for better date display
    plot!(p_imbal, xrotation=45)
    
    # Display plot in separate figure window
    display(p_imbal)
    
    # Store volume statistics for summary
    results["total_volume_reduction"] = total_volume_reduction
    results["avg_daily_volume_reduction"] = avg_daily_volume_reduction
    results["volume_reduction_percentage"] = volume_reduction_percentage
    results["final_cumulative_volume_reduction"] = final_cumulative_volume_reduction
end

# Create a combined comparison plot showing volume reduction from all scenarios
println("\nCreating combined imbalance volume reduction comparison plot...")
p_volume_comparison = plot(
    title="Imbalance Volume Reduction Comparison Across Bidding Strategies",
    xlabel="Date",
    ylabel="Cumulative Volume Reduction (MWh)",
    legend=:topleft,
    size=(1200, 600),
    grid=true,
    margins=5Plots.mm,
    linewidth=3
)

colors = [:blue, :red, :purple]
markers = [:circle, :square, :diamond]

for (i, (scenario_name, results)) in enumerate(all_results)
    daily_aggregated_imbalances = results["aggregated_imbalances"]
    daily_unaggregated_imbalances = results["unaggregated_imbalances"]
    cumulative_volume_reduction = cumsum(daily_unaggregated_imbalances) .- cumsum(daily_aggregated_imbalances)
    
    plot!(p_volume_comparison, results["dates"], cumulative_volume_reduction,
          label=scenario_name,
          color=colors[i],
          marker=markers[i],
          markersize=2,
          alpha=0.8)
end

plot!(p_volume_comparison, xrotation=45)

display(p_volume_comparison)

# =========================
# 4. Print Comprehensive Summary Statistics
# ========================= println("\n" * "="^80)
println("COMPREHENSIVE INCOME TIMELINE SUMMARY")
println("="^80)
println("Simulation period: $(all_results[scenarios[1].name]["dates"][1]) to $(all_results[scenarios[1].name]["dates"][end])")
println("Number of days: $sim_days")
println("Number of clients: $(length(clients))")
println("Clients: $(join(clients, ", "))")
println()

# Print comparison table for income gains
println("INCOME GAINS FROM AGGREGATION COMPARISON:")
println("-"^70)
@printf("%-20s %15s %15s %10s\n", "Scenario", "Total Gains", "Daily Average", "Gains %")
println("-"^70)

for (scenario_name, results) in all_results
    @printf("%-20s %15s %15s %10s\n", 
           scenario_name,
           "€$(round(results["total_gains"], digits=0))",
           "€$(round(results["avg_daily_gains"], digits=2))", 
           "$(round(results["gains_percentage"], digits=1))%")
end
println("-"^70)

# Print comparison table for imbalance volumes
println("\nIMBALANCE VOLUME REDUCTION COMPARISON:")
println("-"^80)
@printf("%-20s %18s %18s %12s\n", "Scenario", "Total Reduction", "Daily Average", "Reduction %")
println("-"^80)

for (scenario_name, results) in all_results
    @printf("%-20s %18s %18s %12s\n", 
           scenario_name,
           "$(round(results["total_volume_reduction"], digits=1)) MWh",
           "$(round(results["avg_daily_volume_reduction"], digits=2)) MWh", 
           "$(round(results["volume_reduction_percentage"], digits=1))%")
end
println("-"^80)

# Detailed summary for each scenario
for (scenario_name, results) in all_results
    println("\n$scenario_name: $(results["description"])")
    println("  INCOME GAINS FROM AGGREGATION:")
    println("    Total gains: €$(round(results["total_gains"], digits=0))")
    println("    Gains percentage: $(round(results["gains_percentage"], digits=1))%")
    println("  IMBALANCE VOLUME REDUCTION:")
    println("    Total volume reduction: $(round(results["total_volume_reduction"], digits=1)) MWh")
    println("    Volume reduction percentage: $(round(results["volume_reduction_percentage"], digits=1))%")
end
