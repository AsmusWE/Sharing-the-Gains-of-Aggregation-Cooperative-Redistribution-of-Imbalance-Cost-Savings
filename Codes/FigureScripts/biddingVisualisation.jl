#This script visualizes how the bids change with different bidding methods
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../Imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
systemData, clients, demandData = load_data()

# Simulation parameters
start_hour = DateTime(2024, 04, 02, 00, 0, 0)
sim_days = 7 # Short simulation for visualization
num_scenarios_demand = 10 # Number of scenarios for demand
num_scenarios_price = 100 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios
alphaCVaR = 0.05 # CVaR confidence level
onePrice = true # Whether to use one-price (true) or two-price (false)

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

# Generate coalitions (we focus on the grand coalition for visualization)
#coalitions = sparse_coalitions(clients)
coalitions = [clients]  # Only the grand coalition for visualization

# =========================
# 2. Calculate Different Bidding Strategies
# =========================
println("Calculating optimal bids (beta=0)...")
optBids = calculate_bids(coalitions, systemData, stochasticData; alpha=alphaCVaR, beta=0.0, onePrice=onePrice)

println("Calculating CVaR-focused bids (beta=1)...")
cvarBids = calculate_bids(coalitions, systemData, stochasticData; alpha=alphaCVaR, beta=1.0, onePrice=onePrice)

println("Calculating dummy bids (mean forecast)...")
# Calculate dummy bids manually to ensure consistency with truncated period
grandCoalition = clients
T = sim_days * 24  # Total hours in simulation

# =========================
# 3. Calculate Net Consumption (Forecast and Actual)
# =========================
# Forecasted net consumption (demand forecast - PV forecast)
demandForecast = get_demand_forecast(grandCoalition, stochasticData, systemData, T)
pvForecast = get_pv_forecast(stochasticData, systemData, T)
# Apply PV ownership scaling (this was missing before!)
total_pv_ownership = sum(systemData["clientPVOwnership"][client] for client in grandCoalition)
netConsForecast = vec(mean(demandForecast, dims=2)) - pvForecast .* total_pv_ownership

# Calculate dummy bids using the same approach as netConsForecast for consistency
dummyBids = Dict()
for coalition in sparse_coalitions(clients)
    coalition_demandForecast = get_demand_forecast(coalition, stochasticData, systemData, T)
    coalition_pvForecast = pvForecast .* sum(systemData["clientPVOwnership"][client] for client in coalition)
    dummyBids[coalition] = vec(mean(coalition_demandForecast, dims=2)) - coalition_pvForecast
end



# Actual net consumption (actual demand - actual PV)
actualDemand = sum(systemData["price_prod_demand_df"][1:T, client] for client in grandCoalition)
actualPV = systemData["price_prod_demand_df"][1:T, :SolarMWh] .* sum(systemData["clientPVOwnership"][client] for client in grandCoalition)
actualNetCons = actualDemand - actualPV

# =========================
# 4. Create Visualization Plots
# =========================
# Create time vector for x-axis
time_hours = collect(1:T)

# Plot 1: Compare bids with net consumption
p1 = plot(
    title="Bidding Strategies vs Net Consumption (Grand Coalition)",
    xlabel="Hour",
    ylabel="Energy [MWh]",
    legend=:outertopright,
    size=(1200, 600)
)

# Plot different bidding strategies
plot!(p1, time_hours, optBids[grandCoalition], 
      label="Optimal Bids (β=0)", 
      linewidth=2, 
      color=:blue)

plot!(p1, time_hours, cvarBids[grandCoalition], 
      label="CVaR Bids (β=1)", 
      linewidth=2, 
      color=:red,
      linestyle=:dash)

plot!(p1, time_hours, dummyBids[grandCoalition], 
      label="Dummy Bids (Median)", 
      linewidth=2, 
      color=:green,
      linestyle=:dot)

# Plot net consumption for reference
plot!(p1, time_hours, netConsForecast, 
      label="Net Consumption Forecast", 
      linewidth=2, 
      color=:orange,
      alpha=0.7)

plot!(p1, time_hours, actualNetCons, 
      label="Actual Net Consumption", 
      linewidth=2, 
      color=:black,
      alpha=0.8)

display(p1)

# Plot 2: Bid values vs Net Consumption
p2 = plot(
    title="Bid Values vs Net Consumption (Grand Coalition)",
    xlabel="Hour", 
    ylabel="Energy [MWh]",
    legend=:outerbottom
)

# Plot bid values from different strategies
plot!(p2, time_hours, optBids[grandCoalition],
      label="Optimal Bid Values (β=0)",
      linewidth=3,
      color=:blue)

plot!(p2, time_hours, cvarBids[grandCoalition],
      label="CVaR Bid Values (β=1)", 
      linewidth=3,
      color=:red,
      linestyle=:dash)

plot!(p2, time_hours, dummyBids[grandCoalition],
      label="Dummy Bid Values",
      linewidth=3,
      color=:green,
      linestyle=:dot)

# Plot mean forecasted net consumption (median across scenarios)
plot!(p2, time_hours, netConsForecast,
      label="Mean Forecasted Net Consumption",
      linewidth=2,
      color=:orange,
      alpha=0.8)

# Plot actual net consumption
plot!(p2, time_hours, actualNetCons,
      label="Actual Net Consumption",
      linewidth=2,
      color=:black,
      alpha=0.9)

display(p2)

# Statistical summary
println("\n=== Summary Statistics ===")
println("Average bid values:")
println("  Optimal bids: $(round(mean(optBids[grandCoalition]), digits=3)) MWh")
println("  CVaR bids: $(round(mean(cvarBids[grandCoalition]), digits=3)) MWh")
println("  Dummy bids: $(round(mean(dummyBids[grandCoalition]), digits=3)) MWh")

println("\nAverage net consumption:")
println("  Mean forecasted: $(round(mean(netConsForecast), digits=3)) MWh")
println("  Actual: $(round(mean(actualNetCons), digits=3)) MWh")

println("\nStandard deviation of bid values:")
println("  Optimal bids: $(round(std(optBids[grandCoalition]), digits=3)) MWh")
println("  CVaR bids: $(round(std(cvarBids[grandCoalition]), digits=3)) MWh") 
println("  Dummy bids: $(round(std(dummyBids[grandCoalition]), digits=3)) MWh")

println("\nDifference from actual net consumption (mean absolute error):")
println("  Optimal bids: $(round(mean(abs.(optBids[grandCoalition] - actualNetCons)), digits=3)) MWh")
println("  CVaR bids: $(round(mean(abs.(cvarBids[grandCoalition] - actualNetCons)), digits=3)) MWh")
println("  Dummy bids: $(round(mean(abs.(dummyBids[grandCoalition] - actualNetCons)), digits=3)) MWh")
println("  Forecasted: $(round(mean(abs.(netConsForecast - actualNetCons)), digits=3)) MWh")