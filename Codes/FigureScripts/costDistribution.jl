# This script solves the bidding problem and generates a figure showing the cost distribution across 15 minute realization


# Imbalance_main.jl
# Main script for running coalition imbalance and allocation analysis
# Author: Asmus Winther Eriksen

# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../Imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization, Statistics #,StatsPlots
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
#clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)
#clients = ["A","G"]

start_hour = DateTime(2024, 06, 01, 00, 0, 0)
simulation_months = 10 # Number of months to simulate
month_length = 30 # Days in a month
total_sim_days = simulation_months * month_length # Calculate total simulation days
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(total_sim_days))
println("Number of simulation months: ", simulation_months)
println("Total simulation days: ", total_sim_days)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 50 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
alphaCVaR = 0.05 # CVaR confidence level
beta = 1 # Weighting factor between cost and CVaR in total cost calculation
dailyPlot = false # Whether to run the daily calculations
dummy = false # Whether to use dummy bids (true) or optimal bids (false)
onePrice = false # Whether to use one-price (true) or two-price (false)



stochasticData = Dict(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    "demand_noise_std" => 0.28,
)

stochasticData["imbalance_spread"], stochasticData["spot_price"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Note: We will not cut systemData here, as we need to slice it month by month


# =========================
# 2. Monthly Imbalance Calculation and Cost Distribution Aggregation
# =========================
coalitions = [clients]
println("Calculating cost distribution using monthly chunks to save RAM...")

# Initialize arrays to store aggregated results
all_grand_costs_timeseries = Float64[]
monthly_imbalance_spreads = Float64[]

for month in 1:simulation_months
    println("Processing month ", month, " of ", simulation_months)
    
    # Set data for current month
    monthData = set_period!(deepcopy(systemData), start_hour + Dates.Day((month-1)*month_length), month_length)
    sim_days = month_length
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour + Dates.Day((month-1)*month_length), month_length; num_scenarios=num_scenarios_demand)
    # Calculate costs for this month
    totalCostsDict, costsDict, cvarDict, imbalancesDict = @time calculate_total_costs_specific(
        monthData, coalitions, stochasticData, sim_days; alpha=alphaCVaR, beta = beta, dummy = dummy, onePrice = onePrice
    )
    
    # Extract cost distribution data for this month
    T_month = sim_days * 24
    imbalance_spread_month = monthData["price_prod_demand_df"][1:T_month, "ImbalanceSpreadEUR"]
    grand_imbalances_month = imbalancesDict[clients]
    grand_costs_timeseries_month = grand_imbalances_month .* imbalance_spread_month
    if !onePrice
        # For two-price scheme, only consider positive costs (costs cannot be negative)
        grand_costs_timeseries_month = max.(0, grand_costs_timeseries_month)
    end
    
    # Append to aggregated arrays
    append!(all_grand_costs_timeseries, grand_costs_timeseries_month)
    append!(monthly_imbalance_spreads, imbalance_spread_month)
    
    # Force garbage collection to free memory
    GC.gc()
end

println("Completed monthly cost distribution calculations. Total time series length: ", length(all_grand_costs_timeseries))

# =========================
# 3. Plot Aggregated Cost Distribution
# =========================
println("Creating cost distribution plot from aggregated monthly data...")

# Calculate VaR at the same confidence level as CVaR using aggregated data
var_level = 1 - alphaCVaR  # Convert alpha to confidence level (95% for alpha=0.05)
var_value = quantile(all_grand_costs_timeseries, var_level)

# Calculate additional statistics
mean_cost = mean(all_grand_costs_timeseries)
median_cost = median(all_grand_costs_timeseries)
max_cost = maximum(all_grand_costs_timeseries)
min_cost = minimum(all_grand_costs_timeseries)

println("Cost distribution statistics:")
println("  Mean cost: $(round(mean_cost, digits=2)) EUR")
println("  Median cost: $(round(median_cost, digits=2)) EUR")
println("  Min cost: $(round(min_cost, digits=2)) EUR")
println("  Max cost: $(round(max_cost, digits=2)) EUR")
println("  VaR ($(round(var_level*100, digits=1))%): $(round(var_value, digits=2)) EUR")

# Calculate percentage of observations above VaR (this should be ~5% by definition for alpha=0.05)
observations_above_var = sum(all_grand_costs_timeseries .> var_value)
total_observations = length(all_grand_costs_timeseries)
percent_observations_above_var = (observations_above_var / total_observations) * 100

# Calculate percentage of total cost above VaR (tail risk concentration)
cost_above_var = sum(filter(x -> x > var_value, all_grand_costs_timeseries))
total_cost = sum(all_grand_costs_timeseries)
percent_cost_above_var = (cost_above_var / total_cost) * 100

println("  Percentage of observations above VaR: $(round(percent_observations_above_var, digits=2))%")
println("  Percentage of total cost above VaR: $(round(percent_cost_above_var, digits=2))%")

# Calculate histogram data once for reuse
hist_data = histogram(all_grand_costs_timeseries, bins=100, normed=false)

# Plot histogram of aggregated cost distribution with extended margins for external legend and annotation
p = histogram(all_grand_costs_timeseries, bins=100, 
    title="Grand Coalition Cost Distribution",
    xlabel="Cost per hour interval (EUR)", 
    ylabel="Frequency", 
    legend=:outerbottom,  # Position legend below the plot area on the right side
    yscale=:log10,
    bottom_margin=15Plots.mm,  # Add bottom margin for legend
    size=(800, 600))  # Specify plot size to accommodate external elements

# Add VaR line
vline!([var_value], color=:red, linewidth=2, linestyle=:dash, 
       label="VaR ($(round(var_level*100, digits=1))%) = $(round(var_value, digits=2)) EUR")

# Add mean line
vline!([mean_cost], color=:blue, linewidth=2, linestyle=:dot, 
       label="Mean = $(round(mean_cost, digits=2)) EUR")

# Create a separate text annotation outside the plot area
# This will be added as a separate plot element below the main plot
annotation_text = "Statistics Summary:\n" *
    "Total hours: $(length(all_grand_costs_timeseries))\n" *
    "Mean: $(round(mean_cost, digits=2)) EUR\n" *
    "Median: $(round(median_cost, digits=2)) EUR\n" *
    "Observations above VaR: $(round(percent_observations_above_var, digits=2))%\n" *
    "Cost above VaR: $(round(percent_cost_above_var, digits=2))%\n" *
    "Total Cost: $(round(total_cost, digits=2)) EUR"

# Create a layout with the main plot and annotation below
p_annotation = plot(framestyle=:none, showaxis=false, grid=false, legend=false, 
                   xlims=(0,1), ylims=(0,1), size=(800, 120))
annotate!(p_annotation, 0.02, 2.5, text(annotation_text, :black, 9, :left))

# Combine the main plot and annotation
p_combined = plot(p, p_annotation, layout=grid(2,1, heights=[0.9, 0.1]))

display(p_combined)




