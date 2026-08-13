# In this script the maximum excess of different ratios between flat rate (socialized) and uniform price (individualized) costs is calculated.

# --- Project Modules ---
include("../common_setup.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization, DataFrames #,StatsPlots
Random.seed!(1) # Set seed for reproducibility

# =========================
# 1. Data Loading & Setup
# =========================
# Choose which individualized allocation to calculate
# Should be flat_rate and one other
allocations = ["marginal_price", "flat_rate"]
individualized_allocation = "marginal_price" # Choose which individualized allocation to compare to flat rate
socialized_allocation = "flat_rate" # Choose which socialized allocation to compare to individualized

system_data, clients, demand_data = load_data()
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
one_price = false # Whether to use a one price or two price settlement for imbalance costs
check_excess = true # Whether to check excess for the allocations, requires computing all combinations
use_newsvendor = true # Whether to use newsvendor approach for imbalance cost calculation
full_opt = false # Whether to use full optimization for imbalance cost calculation, or just expected values

# Individualization parameters
individualization_steps = 0:0.05:1 # Ratio between socialized (flat rate) and individualized (uniform price) costs, 0 means all socialized, 1 means all individualized

stochastic_data = Dict(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    "demand_noise_std" => 0.28,
)

if stochastic_data["demand_forecast"] == "scenarios"
    stochastic_data["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demand_data, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end
stochastic_data["imbalance_spread"], stochastic_data["spot_price"] = generate_scenarios_imbalance_spread(system_data, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochastic_data["dominant_direction_scenarios"] = generate_dominant_direction(stochastic_data["imbalance_spread"])

# Keep original demand_data for scenario generation (needs historical data)
original_demand_data = deepcopy(demand_data)

# Cut system_data and demand_data to the simulation period
system_data = set_period(system_data, start_hour, sim_days)
demand_data = set_period(demand_data, start_hour, sim_days)

# =========================
# 2. Imbalance Calculation and allocation
# =========================
if check_excess
    coalitions = collect(combinations(clients))
else
    coalitions = sparse_coalitions(clients)
end

# =========================
# 3. Excess calculation
# =========================

# Build a DataFrame: rows = individualization steps, columns = clients
# Store maximum excess for each step
max_excess_by_step = Float64[]

println("Calculating total costs")

# Initialize accumulation dictionaries across reconciliation periods
accumulated_coalition_costs = Dict(coalition => 0.0 for coalition in coalitions)
accumulated_coalition_imbalances = Dict(coalition => Float64[] for coalition in coalitions)

# Optimize in reconciliation periods (7 days at a time)
reconciliation_period_days = 7
num_periods = Int(ceil(sim_days / reconciliation_period_days))

for period in 1:num_periods
    # Calculate the start day and length for this period
    period_start_day = (period - 1) * reconciliation_period_days + 1
    days_in_period = min(reconciliation_period_days, sim_days - period_start_day + 1)

    println("Processing period $period of $num_periods (days $period_start_day to $(period_start_day + days_in_period - 1))")

    # Create system data for this period
    period_start = start_hour + Dates.Day(period_start_day - 1)
    period_system_data = set_period(deepcopy(system_data), period_start, days_in_period)

    # Generate demand scenarios for this specific period
    stochastic_data["demand_scenarios"] = generate_scenarios_demand_rolling(clients, original_demand_data, period_start, days_in_period; num_scenarios=num_scenarios_demand)

    # Calculate costs for this period
    period_coalition_costs, period_coalition_imbalances = @time calculate_total_costs_specific(
        period_system_data, coalitions, stochastic_data, days_in_period; dummy = dummy, one_price = one_price, use_newsvendor = use_newsvendor, full_opt = full_opt
    )

    # Accumulate results for this period
    for coalition in coalitions
        accumulated_coalition_costs[coalition] += period_coalition_costs[coalition]
        append!(accumulated_coalition_imbalances[coalition], period_coalition_imbalances[coalition])
    end
end

allocation_costs = calculate_allocations(
    allocations, clients, accumulated_coalition_costs, accumulated_coalition_imbalances, system_data; printing = true
)

println("Total costs: ", accumulated_coalition_costs[clients])
mixed_allocation_df = DataFrame(step = collect(individualization_steps))
for client in clients
    flat = allocation_costs[socialized_allocation][client]
    indiv = allocation_costs[individualized_allocation][client]
    mixed_allocation_df[!, client] = (1 .- mixed_allocation_df.step) .* flat .+ mixed_allocation_df.step .* indiv
end

# Checking stability of the mixed allocations
if check_excess
    for row in eachrow(mixed_allocation_df)
        step_allocation = Dict(client => row[client] for client in clients)
        max_excess_step = check_stability(step_allocation, accumulated_coalition_costs, clients)
        push!(max_excess_by_step, max_excess_step)
        println("Max excess for mixed allocation (step = ", row[:step], "): ", max_excess_step)
    end
end

# =========================
# 3.b. Find step where max excess becomes negative
# =========================
negative_excess_step = nothing
if check_excess && !isempty(max_excess_by_step)
    for (i, excess) in enumerate(max_excess_by_step)
        if excess < 0
            global negative_excess_step = individualization_steps[i]
            println("First individualization step where max excess is negative: ", negative_excess_step)
            break
        end
    end
    if isnothing(negative_excess_step)
        println("Max excess never becomes negative in the analyzed range")
    end
end

# =========================
# 3.a. Cost per MWh demand
# =========================
# For each client compute their (allocated) cost per MWh of demand for every individualization step.
# Uses total demand over the simulation horizon (same for every step) as denominator.
total_demand_by_client = Dict(client => sum(system_data["price_prod_demand_df"][!, client]) for client in clients)
mixed_allocation_cost_per_mwh_df = DataFrame(step = mixed_allocation_df.step)
for client in clients
    denom = total_demand_by_client[client]
    if isnothing(denom) || denom == 0
        mixed_allocation_cost_per_mwh_df[!, client] = fill(missing, nrow(mixed_allocation_df))
    else
        mixed_allocation_cost_per_mwh_df[!, client] = mixed_allocation_df[!, client] ./ denom
    end
end


# =========================
# 4. Scatter Plot: Cost per MWh vs Individualization Step
# =========================
# Flip sign to go from the negative-is-cost convention to positive-for-display
mixed_allocation_cost_per_mwh_df_plot = copy(mixed_allocation_cost_per_mwh_df)
for client in clients
    mixed_allocation_cost_per_mwh_df_plot[!, client] = -mixed_allocation_cost_per_mwh_df[!, client]
end

p = plot(
    #title = "Client Cost per MWh vs Individualization Grade",
    xlabel = "Individualization Grade",
    ylabel = "Imbalance Cost per MWh (EUR/MWh)",
    background_color = :white,
    foreground_color_subplot = :black,
    size = (780, 600),
    guidefontsize=16,
    legendfontsize=14
)

# Create color gradient from blue (high cost) to pink (low cost) based on final individualized cost
final_costs = [mixed_allocation_cost_per_mwh_df_plot[end, client] for client in clients]
cost_order = sortperm(final_costs, rev=true)  # High to low
color_gradient = range(colorant"#0066CC", stop=colorant"#FF69B4", length=length(clients))
palette_colors = [color_gradient[findfirst(==(i), cost_order)] for i in 1:length(clients)]

for (i, client) in enumerate(clients)
    plot!(p,
        mixed_allocation_cost_per_mwh_df_plot.step,
        mixed_allocation_cost_per_mwh_df_plot[!, client],
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
if !isnothing(negative_excess_step)
    vline!(p, [negative_excess_step],
           color = :red,
           linestyle = :dash,
           linewidth = 2,
           label = "Line of Stability")
end

display(p)
