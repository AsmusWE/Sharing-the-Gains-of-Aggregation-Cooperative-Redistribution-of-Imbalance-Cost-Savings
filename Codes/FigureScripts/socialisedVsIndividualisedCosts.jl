# In this script the maximum excess of different ratios between flat rate (socialised) and uniform price (individualised) costs is calculated.

# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization, DataFrames #,StatsPlots
Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
# Choose which individualised allocation to calculate
# Should be flat_rate and one other
allocations = ["gately", "flat_rate"]
individualAllocation = "gately" # Choose which individualised allocation to compare to flat rate

systemData, clients, demandData = load_data()
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)
#clients = ["A","G","I","S","Y"]
#clients = ["A","G"]

start_hour = DateTime(2024, 01, 02, 00, 0, 0)
sim_days = 365
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 50 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
beta = 0 # Weighting factor between cost and CVaR in total cost calculation
dummy = true # Whether to do dummy bidding, overwrites optimization to bid expected net consumption
onePrice = false # Whether to use a one price or two price settlement for imbalance costs

# Individualization parameters
individualizationSteps = 0:0.1:1 # Ratio between socialised (flat rate) and individualised (uniform price) costs, 0 means all socialised, 1 means all individualised
# TODO: Implement individualizedCVaR = true option
individualizedCVaR = false # If true, the individualized part will be based on CVaR, otherwise on percentage of total costs
alphaCVaR = 0.95
#if individualizationRatio == 0
#    alphaCVaR = 0.5 # If all socialised, CVaR level is a design parameter, set to 0.95
#else
#    alphaCVaR = 1 - individualizationRatio # CVaR confidence level, 0.95 means 5% worst cases
#end

stochasticData = Dict(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
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
# 2. Imbalance Calculation and allocation
# =========================
coalitions = collect(combinations(clients))
println("Calculating total costs (regular costs + CVaR)")
totalCostsDict, costsDict, cvarDict, imbalancesDict = @time calculate_total_costs_specific(
    systemData, coalitions, stochasticData, sim_days; alpha=alphaCVaR, beta = beta, dummy = dummy, onePrice = onePrice
)

allocation_costs = calculate_allocations(
    allocations, clients, costsDict, imbalancesDict, systemData; printing = true, alpha=alphaCVaR
)

println("Total costs (regular + CVaR): ", totalCostsDict[clients])
println("Regular costs only: ", costsDict[clients])
println("CVaR only: ", cvarDict[clients])

# =========================
# 3. Excess calculation
# =========================

# Build a DataFrame: rows = individualization steps, columns = clients
if individualizedCVaR
    error("individualizedCVaR = true not implemented in this script for mixed allocation. Set individualizedCVaR = false or implement CVaR-based per-client allocation.")
else
    mixedAllocationDF = DataFrame(step = collect(individualizationSteps))
    for client in clients
        flat = allocation_costs["flat_rate"][client]
        indiv = allocation_costs[individualAllocation][client]
        mixedAllocationDF[!, client] = (1 .- mixedAllocationDF.step) .* flat .+ mixedAllocationDF.step .* indiv
    end
end

# =========================
# 3.a. Cost per MWh demand
# =========================
# For each client compute their (allocated) cost per MWh of demand for every individualization step.
# Uses total demand over the simulation horizon (same for every step) as denominator.
totalDemandByClient = Dict(client => sum(systemData["price_prod_demand_df"][!, client]) for client in clients)
mixedAllocationCostPerMWhDF = DataFrame(step = mixedAllocationDF.step)
for client in clients
    denom = totalDemandByClient[client]
    if isnothing(denom) || denom == 0
        mixedAllocationCostPerMWhDF[!, client] = fill(missing, nrow(mixedAllocationDF))
    else
        mixedAllocationCostPerMWhDF[!, client] = mixedAllocationDF[!, client] ./ denom
    end
end

for row in eachrow(mixedAllocationDF)
    stepAllocation = Dict(client => row[client] for client in clients)
    maxExcessStep = check_stability(stepAllocation, costsDict, clients)
    println("Max excess for mixed allocation (step = ", row[:step], "): ", maxExcessStep)
end

# =========================
# 4. Scatter Plot: Cost per MWh vs Individualization Step
# =========================
p = plot(
    title = "Allocated Cost per MWh vs Individualization Step",
    xlabel = "Individualization step (0 = all socialised, 1 = all individualised)",
    ylabel = "Cost per MWh (EUR/MWh)",
    background_color = :white,
    foreground_color_subplot = :black,
    size = (1100, 650)
)
palette_colors = palette(:tab10, length(clients))
for (i, client) in enumerate(clients)
    scatter!(p,
        mixedAllocationCostPerMWhDF.step,
        mixedAllocationCostPerMWhDF[!, client],
        label = client,
        markersize = 5,
        markerstrokewidth = 0.5,
        color = palette_colors[i]
    )
    plot!(p,
        mixedAllocationCostPerMWhDF.step,
        mixedAllocationCostPerMWhDF[!, client],
        label = "",
        color = palette_colors[i],
        lw = 1
    )
end
display(p)