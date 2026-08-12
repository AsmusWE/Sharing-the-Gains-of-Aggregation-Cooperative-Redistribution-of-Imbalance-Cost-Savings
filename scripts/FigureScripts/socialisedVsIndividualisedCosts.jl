# In this script the maximum excess of different ratios between flat rate (socialised) and uniform price (individualised) costs is calculated.

# --- Project Modules ---
include("../common_setup.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization, DataFrames #,StatsPlots
Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
# Choose which individualised allocation to calculate
# Should be flat_rate and one other
allocations = ["full_cost", "flat_rate"]
individualAllocation = "full_cost" # Choose which individualised allocation to compare to flat rate
socialisedAllocation = "flat_rate" # Choose which socialised allocation to compare to individualised

systemData, clients, demandData = load_data()
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
clients = filter(x -> !(x in ["X", "W"]), clients)
# Filter down to 12 for nucleolus
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y", "H"]), clients)
#clients = ["A","G","I","S","Y"]
#clients = ["A","G"]

start_hour = DateTime(2024, 01, 02, 00, 0, 0)
sim_days = 365
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 50 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
dummy = false # Whether to do dummy bidding, overwrites optimization to bid expected net consumption
onePrice = false # Whether to use a one price or two price settlement for imbalance costs
checkExcess = true # Whether to check excess for the allocations, requires computing all combinations
useNewsvendor = true # Whether to use newsvendor approach for imbalance cost calculation
fullOpt = false # Whether to use full optimization for imbalance cost calculation, or just expected values

# Individualization parameters
individualizationSteps = 0:0.05:1 # Ratio between socialised (flat rate) and individualised (uniform price) costs, 0 means all socialised, 1 means all individualised

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

# Keep original demandData for scenario generation (needs historical data)
originalDemandData = deepcopy(demandData)

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)

# =========================
# 2. Imbalance Calculation and allocation
# =========================
if checkExcess
    coalitions = collect(combinations(clients))
else
    coalitions = sparse_coalitions(clients)
end



# =========================
# 3. Excess calculation
# =========================

# Build a DataFrame: rows = individualization steps, columns = clients
# Store maximum excess for each step
maxExcessByStep = Float64[]

println("Calculating total costs")

# Initialize accumulation dictionaries for weekly costs
accumulated_costsDict = Dict(coalition => 0.0 for coalition in coalitions)
accumulated_imbalancesDict = Dict(coalition => Float64[] for coalition in coalitions)

# Optimize week by week (7 days at a time)
week_length = 7
num_weeks = Int(ceil(sim_days / week_length))

for week in 1:num_weeks
    # Calculate the start day and length for this week
    week_start_day = (week - 1) * week_length + 1
    days_in_week = min(week_length, sim_days - week_start_day + 1)

    println("Processing week $week of $num_weeks (days $week_start_day to $(week_start_day + days_in_week - 1))")

    # Create weekly system data
    current_week_start = start_hour + Dates.Day(week_start_day - 1)
    weekly_systemData = set_period!(deepcopy(systemData), current_week_start, days_in_week)

    # Generate demand scenarios for this specific week
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, originalDemandData, current_week_start, days_in_week; num_scenarios=num_scenarios_demand)

    # Calculate costs for this week
    weeklyCostsDict, weeklyImbalancesDict = @time calculate_total_costs_specific(
        weekly_systemData, coalitions, stochasticData, days_in_week; dummy = dummy, onePrice = onePrice, useNewsvendor = useNewsvendor, fullOpt = fullOpt
    )

    # Accumulate weekly results
    for coalition in coalitions
        accumulated_costsDict[coalition] += weeklyCostsDict[coalition]
        append!(accumulated_imbalancesDict[coalition], weeklyImbalancesDict[coalition])
    end
end

allocation_costs = calculate_allocations(
    allocations, clients, accumulated_costsDict, accumulated_imbalancesDict, systemData; printing = true
)

println("Total costs: ", accumulated_costsDict[clients])
mixedAllocationDF = DataFrame(step = collect(individualizationSteps))
for client in clients
    flat = allocation_costs[socialisedAllocation][client]
    indiv = allocation_costs[individualAllocation][client]
    mixedAllocationDF[!, client] = (1 .- mixedAllocationDF.step) .* flat .+ mixedAllocationDF.step .* indiv
end

# Checking stability of the mixed allocations
if checkExcess
    for row in eachrow(mixedAllocationDF)
        stepAllocation = Dict(client => row[client] for client in clients)
        maxExcessStep = check_stability(stepAllocation, accumulated_costsDict, clients)
        push!(maxExcessByStep, maxExcessStep)
        println("Max excess for mixed allocation (step = ", row[:step], "): ", maxExcessStep)
    end
end

# =========================
# 3.b. Find step where max excess becomes negative
# =========================
negativeExcessStep = nothing
if checkExcess && !isempty(maxExcessByStep)
    for (i, excess) in enumerate(maxExcessByStep)
        if excess < 0
            global negativeExcessStep = individualizationSteps[i]
            println("First individualization step where max excess is negative: ", negativeExcessStep)
            break
        end
    end
    if isnothing(negativeExcessStep)
        println("Max excess never becomes negative in the analyzed range")
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


# =========================
# 4. Scatter Plot: Cost per MWh vs Individualization Step
# =========================
# Flip sign to convert from income to cost for plotting
mixedAllocationCostPerMWhDF_plot = copy(mixedAllocationCostPerMWhDF)
for client in clients
    mixedAllocationCostPerMWhDF_plot[!, client] = -mixedAllocationCostPerMWhDF[!, client]
end

p = plot(
    #title = "Client Cost per MWh vs Individualisation Grade",
    xlabel = "Individualisation Grade",
    ylabel = "Imbalance Cost per MWh (EUR/MWh)",
    background_color = :white,
    foreground_color_subplot = :black,
    size = (780, 600),
    guidefontsize=16,
    legendfontsize=14
)

# Create color gradient from blue (high cost) to pink (low cost) based on final individualized cost
final_costs = [mixedAllocationCostPerMWhDF_plot[end, client] for client in clients]
cost_order = sortperm(final_costs, rev=true)  # High to low
color_gradient = range(colorant"#0066CC", stop=colorant"#FF69B4", length=length(clients))
palette_colors = [color_gradient[findfirst(==(i), cost_order)] for i in 1:length(clients)]

for (i, client) in enumerate(clients)
    #scatter!(p,
    #    mixedAllocationCostPerMWhDF_plot.step,
    #    mixedAllocationCostPerMWhDF_plot[!, client],
    #    label = "client $client",
    #    markersize = 5,
    #    markerstrokewidth = 0.5,
    #    color = palette_colors[i]
    #)
    plot!(p,
        mixedAllocationCostPerMWhDF_plot.step,
        mixedAllocationCostPerMWhDF_plot[!, client],
        label = (i == 1 ? "Individual Client Cost" : ""),
        color = palette_colors[i],
        lw = 1,
        # Increase axis label and tick font sizes
        xguidefont = font(18),
        yguidefont = font(18),
        xtickfont = font(14),
        ytickfont = font(14),
    )
end

# Add vertical line where max excess becomes negative
if !isnothing(negativeExcessStep)
    vline!(p, [negativeExcessStep], 
           color = :red, 
           linestyle = :dash, 
           linewidth = 2,
           label = "Line of Stability")
end

display(p)