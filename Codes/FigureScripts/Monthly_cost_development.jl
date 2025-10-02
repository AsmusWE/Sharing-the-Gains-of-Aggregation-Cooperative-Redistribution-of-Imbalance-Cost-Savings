# Optimize once for entire period, then calculate daily allocations and plot monthly costs
# Approach: Single optimization → extract hourly data → calculate daily allocations → aggregate to monthly
# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../Imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

using Plots, Dates, Random, Combinatorics, Serialization
GC.gc()
Random.seed!(1)

# =========================
# 1. Data Loading & Setup
# =========================

systemData, clients, demandData = load_data()
#clients = filter(x -> !(x in ["X", "W", "N", "F", "V", "J","E", "T", "O", "Y"]), clients)
clients = ["A","G","I","S","Q"]

start_hour = DateTime(2024, 01, 01, 00, 0, 0)
total_sim_days = 365
dummy = false
onePrice = false

num_scenarios_demand = 5
num_scenarios_price = 50
spread_scens_length = 1
alphaCVaR = 0.95
beta = 0.5

# Allocation method selection: "gately" or "full_cost"
allocation_method = "full_cost"  # Change this to "gately" to switch allocation methods

stochasticData = Dict(
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    "demand_noise_std" => 0.28,
)

# =========================
# 2. Daily Optimization and Allocation
# =========================
allocations = ["VCG", allocation_method, "full_cost"]  # Only methods compatible with simple calculations
coalitions = sparse_coalitions(clients)
println("Running daily optimization and calculating allocations...")

# Initialize storage
dailyAllocationCosts = []
dailyClientDemand = []
dailyImbalancesDict = []
all_grand_income_timeseries = []
all_timestamps = []


# Process each day individually
for day in 1:total_sim_days
    println("Processing day $day/$total_sim_days...")
    
    # Setup daily data
    day_start_date = start_hour + Dates.Day(day-1)
    daily_systemData = set_period!(systemData, day_start_date, 1)
    
    # Generate scenarios for this day
    daily_stochasticData = Dict(
        "pv_forecast" => "scenarios",
        "demand_forecast" => "scenarios",
        "demand_noise_std" => 0.28,
    )
    
    daily_stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, day_start_date, 1; num_scenarios=num_scenarios_demand)
    daily_stochasticData["imbalance_spread"], daily_stochasticData["spot_price"] = generate_scenarios_imbalance_spread(systemData, day_start_date, spread_scens_length; num_scenarios=num_scenarios_price)
    daily_stochasticData["dominantDirection01"] = generate_dominant_direction(daily_stochasticData["imbalance_spread"])
    
    # Calculate daily costs and imbalances using proper functions
    daily_coalition_costs, daily_regular_costs, daily_cvar_costs, daily_imbalances = calculate_total_costs_specific(
        daily_systemData, coalitions, daily_stochasticData, 1; alpha=alphaCVaR, beta=beta, dummy=dummy, onePrice=onePrice
    )
    
    # Store daily imbalances
    push!(dailyImbalancesDict, daily_imbalances)
    
    # Calculate daily allocations using proper game theory functions
    daily_allocation_costs = calculate_allocations(
        allocations, clients, daily_regular_costs, daily_imbalances, daily_systemData; printing=false, alpha=alphaCVaR
    )
    push!(dailyAllocationCosts, daily_allocation_costs)
    
    # Calculate daily demand
    clientDemand = Dict(client => sum(daily_systemData["price_prod_demand_df"][!, client]) for client in clients)
    push!(dailyClientDemand, clientDemand)
    
    # Calculate daily grand coalition income for plotting using daily_regular_costs
    daily_grand_income = daily_regular_costs[clients]
    
    # Store daily grand coalition income for cumulative plotting
    push!(all_grand_income_timeseries, daily_grand_income)
    
    # Create daily timestamp for this day (end of day for proper alignment)
    daily_timestamp = day_start_date + Dates.Hour(23)
    push!(all_timestamps, daily_timestamp)
end

# Calculate cumulative income for plotting
cumulative_income_timeseries = cumsum(all_grand_income_timeseries)

# =========================
# 3. Calculate Flat Rate and CVaR Payments
# =========================
# Calculate flat rate to balance grand coalition income
total_grand_coalition_income = sum(all_grand_income_timeseries)
total_demand_all_clients = sum(sum(dailyClientDemand[day][client] for client in clients) for day in 1:total_sim_days)
flat_rate_fee = -total_grand_coalition_income / total_demand_all_clients
println("Flat rate fee: $(round(flat_rate_fee, digits=4)) EUR/MWh")

# Calculate daily flat rate income for each client
dailyClientFlatRateIncome = []
daily_total_flat_rate_income = []
for day in 1:total_sim_days
    daily_flat_rate = Dict{String, Float64}()
    for client in clients
        # Flat rate income = demand * flat_rate_fee (note: flat_rate_fee is already negative for income)
        daily_flat_rate[client] = dailyClientDemand[day][client] * flat_rate_fee
    end
    push!(dailyClientFlatRateIncome, daily_flat_rate)
    # Calculate total flat rate for this day
    push!(daily_total_flat_rate_income, sum(values(daily_flat_rate)))
end

println("Creating combined daily costs plot with cumulative values...")

# Initialize plot
allocation_name = allocation_method == "gately" ? "Gately" : "Full Cost"
p = plot(
    title="Cumulative Grand Coalition Income vs Individual $(allocation_name) Allocation Income\n(Daily Optimization, Daily Data Points)",
    xlabel="Date",
    ylabel="Cumulative Income (EUR)",
    legend=:outertopright,
    size=(1400, 700),
    grid=true,
    margins=8Plots.mm,
    tickfontsize=11,
    guidefontsize=13,
    titlefontsize=15,
    legendfontsize=10
)

# Plot grand coalition cumulative income (from daily_regular_costs)
plot!(p, all_timestamps, cumulative_income_timeseries, 
      label="Grand Coalition Cumulative Income (Daily Data)", 
      linewidth=4,
      color=:black,
      linestyle=:solid)

# Plot individual client allocation costs (daily cumulative)
for client in clients
    daily_allocation_costs = []
    for day in 1:total_sim_days
        if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
            push!(daily_allocation_costs, dailyAllocationCosts[day][allocation_method][client])
        else
            push!(daily_allocation_costs, 0.0)
        end
    end
    
    # Make cumulative and sample at daily intervals
    cumulative_allocation_costs = cumsum(daily_allocation_costs)
    # Create daily timestamps for allocation data (end of each day for proper alignment)
    daily_timestamps = [start_hour + Dates.Day(day-1) + Dates.Hour(23) for day in 1:total_sim_days]
    
    plot!(p, daily_timestamps, cumulative_allocation_costs, 
          label="Client $client ($(allocation_name) Daily)", 
          linewidth=2,
          alpha=0.8)
end

# Also add the sum of allocations for comparison
daily_total_allocations = []
for day in 1:total_sim_days
    total_allocation = 0.0
    if haskey(dailyAllocationCosts[day], allocation_method)
        total_allocation = sum(values(dailyAllocationCosts[day][allocation_method]))
    end
    push!(daily_total_allocations, total_allocation)
end

# Make cumulative
cumulative_total = cumsum(daily_total_allocations)
daily_timestamps = [start_hour + Dates.Day(day-1) + Dates.Hour(23) for day in 1:total_sim_days]

plot!(p, daily_timestamps, cumulative_total, 
      label="$(allocation_name) Total (Sum, Daily)", 
      linewidth=3,
      color=:red,
      linestyle=:dash)

# Format x-axis for better date display
plot!(p, xrotation=45)

display(p)

# =========================
# 4. Plot Client Costs: Allocation vs Flat Rate vs Difference (Daily Data)
# =========================
println("Creating client cost comparison plot from daily data...")

# Create subplots for each client plus one for grand coalition
num_clients = length(clients)
p_clients = plot(layout=(num_clients + 1, 1), size=(1400, 500*(num_clients + 1)))

# Create daily time axis for allocation data (end of each day for proper alignment)
daily_time_axis = [start_hour + Dates.Day(day-1) + Dates.Hour(23) for day in 1:total_sim_days]

# Define daily_total_allocation_pos using the cumulative_total calculated earlier
daily_total_allocation_pos = cumulative_total

# Make flat rate cumulative using the already calculated daily_total_flat_rate_income
daily_total_flat_rate_pos = cumsum(daily_total_flat_rate_income)

# Calculate total net position (allocation + flat rate)
daily_total_net_position = daily_total_allocation_pos .+ daily_total_flat_rate_pos

for (i, client) in enumerate(clients)
    # Extract daily allocation costs for this client
    daily_allocation_costs = []
    for day in 1:total_sim_days
        if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
            push!(daily_allocation_costs, dailyAllocationCosts[day][allocation_method][client])
        else
            push!(daily_allocation_costs, 0.0)
        end
    end
    
    # Extract daily flat rate income for this client
    daily_flat_rate_income = [dailyClientFlatRateIncome[day][client] for day in 1:total_sim_days]
    
    # Make all values cumulative
    daily_allocation_income_pos = cumsum(daily_allocation_costs)
    daily_flat_rate_income_pos = cumsum(daily_flat_rate_income)
    
    # Calculate the sum (net position: income + income)
    daily_net_position = daily_flat_rate_income_pos .+ daily_allocation_income_pos
    
    # Plot for this client using daily data points
    plot!(p_clients[i], daily_time_axis, daily_allocation_income_pos, 
          label="Cumulative $(allocation_name) Allocated Income", 
          linewidth=3,
          color=:blue,
          title="Client $client: Cumulative Financial Position\n(Daily Optimization, Daily Data Points)",
          xlabel="Date",
          ylabel="Cumulative Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_clients[i], daily_time_axis, daily_flat_rate_income_pos, 
          label="Cumulative Monthly Flat Rate Payment ($(round(flat_rate_fee, digits=2))€/MWh)", 
          linewidth=3,
          color=:green)
    
    plot!(p_clients[i], daily_time_axis, daily_net_position, 
          label="Cumulative Net Position (Total Income)", 
          linewidth=3,
          color=:red,
          linestyle=:dash)
    
    # Add horizontal line at zero for reference
    hline!(p_clients[i], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

# Add total system subplot
if length(clients) > 0
    # Reuse the already calculated daily totals from section 4
    subplot_index = num_clients + 1
    plot!(p_clients[subplot_index], daily_time_axis, daily_total_allocation_pos, 
          label="Cumulative Total $(allocation_name) Allocated Income", 
          linewidth=3,
          color=:blue,
          title="Grand Coalition: Cumulative Financial Position\n(Daily Optimization, Daily Data Points)",
          xlabel="Date",
          ylabel="Cumulative Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_clients[subplot_index], daily_time_axis, daily_total_flat_rate_pos, 
          label="Cumulative Total Monthly Flat Rate Payments (Income)", 
          linewidth=3,
          color=:green)
    
    plot!(p_clients[subplot_index], daily_time_axis, daily_total_net_position, 
          label="Cumulative Total Net Position (Total Income)", 
          linewidth=3,
          color=:red,
          linestyle=:dash)
    
    # Add horizontal line at zero for reference
    hline!(p_clients[subplot_index], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_clients)

# =========================
# 4b. Calculate Monthly Reconciliation Data
# =========================
# Create monthly reconciliation by calculating the difference between allocated income and flat rate payments
# Group by month and calculate reconciliation needed to balance the accounts

# Create monthly dates for the simulation period
start_date = Date(start_hour)
end_date = Date(start_hour + Dates.Day(total_sim_days - 1))

# Generate monthly dates using a simple approach
first_month = Date(year(start_date), month(start_date), 1)
last_month = Date(year(end_date), month(end_date), 1)

# Calculate number of months manually
start_year_month = year(first_month) * 12 + month(first_month)
end_year_month = year(last_month) * 12 + month(last_month)
num_months = end_year_month - start_year_month + 1

# Create monthly dates using comprehension
monthly_dates = [first_month + Dates.Month(i) for i in 0:(num_months-1)]

# Initialize monthly reconciliation dictionary
monthly_reconciliation = Dict{String, Vector{Float64}}()
for client in clients
    monthly_reconciliation[client] = zeros(length(monthly_dates))
end

# Calculate monthly reconciliation for each client
for (month_idx, month_date) in enumerate(monthly_dates)
    # Find days in this month
    month_days = []
    for day in 1:total_sim_days
        day_date = Date(start_hour + Dates.Day(day - 1))
        if Date(year(day_date), month(day_date), 1) == month_date
            push!(month_days, day)
        end
    end
    
    # Calculate monthly totals for each client
    for client in clients
        month_allocation_total = 0.0
        month_flat_rate_total = 0.0
        
        for day in month_days
            # Add allocation income for this day
            if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
                month_allocation_total += dailyAllocationCosts[day][allocation_method][client]
            end
            
            # Add flat rate payment for this day
            month_flat_rate_total += dailyClientFlatRateIncome[day][client]
        end
        
        # Reconciliation = -(allocation + flat_rate) to balance to zero
        monthly_reconciliation[client][month_idx] = -(month_allocation_total + month_flat_rate_total)
    end
end

# =========================
# 5. Combined System Plot - Showing the Complete Payment Flow with Reconciliation
# =========================
println("Creating combined system plot showing complete payment flow with monthly reconciliation...")

p_combined = plot(layout=(length(clients) + 1, 1), size=(1400, 600*(length(clients) + 1)))

# Create a function to expand monthly reconciliation to daily timeline
function expand_monthly_reconciliation_to_daily(monthly_reconciliation, monthly_dates, start_date, total_days)
    daily_reconciliation = zeros(total_days)
    
    for day in 1:total_days
        current_date = Date(start_date + Dates.Day(day-1))
        current_month = Date(year(current_date), month(current_date), 1)
        
        # Find which month this day belongs to
        month_index = findfirst(d -> d == current_month, monthly_dates)
        
        # Check if this is the last day of the month
        next_day = current_date + Dates.Day(1)
        is_last_day_of_month = month(next_day) != month(current_date) || day == total_days
        
        # Apply reconciliation on the last day of the month
        if is_last_day_of_month && month_index !== nothing
            daily_reconciliation[day] = monthly_reconciliation[month_index]
        end
    end
    
    return daily_reconciliation
end

# Create payment flow visualization for each client
for (i, client) in enumerate(clients)
    # Reuse the already extracted daily data from section 4
    daily_allocation_costs = []
    for day in 1:total_sim_days
        if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
            push!(daily_allocation_costs, dailyAllocationCosts[day][allocation_method][client])
        else
            push!(daily_allocation_costs, 0.0)
        end
    end
    
    daily_flat_rate_income = [dailyClientFlatRateIncome[day][client] for day in 1:total_sim_days]
    
    # Expand monthly reconciliation to daily timeline
    daily_reconciliation = expand_monthly_reconciliation_to_daily(
        monthly_reconciliation[client], monthly_dates, start_hour, total_sim_days
    )
    
    # Calculate cumulative values
    cumulative_allocation = cumsum(daily_allocation_costs)
    cumulative_flat_rate = cumsum(daily_flat_rate_income)
    cumulative_reconciliation = cumsum(daily_reconciliation)
    
    # Total effective payment = flat rate + reconciliation adjustments
    total_effective_payment = cumulative_flat_rate .+ cumulative_reconciliation
    
    # Calculate the sum of allocated income and total payments (should be zero)
    payment_allocation_sum = cumulative_allocation .+ total_effective_payment
    
    # Plot the complete payment system
    plot!(p_combined[i], daily_time_axis, cumulative_flat_rate,
          label="Cumulative Flat Rate Payments",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="Client $client: Flat rate and reconciliation",
          xlabel="Date",
          ylabel="Cumulative Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined[i], daily_time_axis, cumulative_allocation,
          label="Allocated Income",
          linewidth=2,
          color=:blue)
    
    plot!(p_combined[i], daily_time_axis, payment_allocation_sum,
          label="Cumulative Net Position",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    # Add reconciliation adjustments as step changes
    #plot!(p_combined[i], daily_time_axis, cumulative_reconciliation,
    #      label="Cumulative Reconciliation Adjustments",
    #      linewidth=2,
    #      color=:orange,
    #      linestyle=:dot)
    
    # Add the difference line
    plot!(p_combined[i], daily_time_axis, total_effective_payment,
          label="Total Effective Payment (Flat rate + Reconciliation)",
          linewidth=2,
          color=:purple,
          alpha=0.7)
    
    # Add horizontal line at zero for reference
    hline!(p_combined[i], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

# Add total system subplot
if length(clients) > 0
    # Calculate totals across all clients
    total_daily_allocation = []
    total_daily_flat_rate = []
    
    # Reuse the already calculated totals from section 4
    cumulative_total_allocation = daily_total_allocation_pos  # Already calculated in section 4
    cumulative_total_flat_rate = daily_total_flat_rate_pos   # Already calculated in section 4
    
    # Calculate total reconciliation across all clients
    total_daily_reconciliation = zeros(total_sim_days)
    for client in clients
        daily_reconciliation = expand_monthly_reconciliation_to_daily(
            monthly_reconciliation[client], monthly_dates, start_hour, total_sim_days
        )
        total_daily_reconciliation .+= daily_reconciliation
    end
    
    # Calculate cumulative reconciliation
    cumulative_total_reconciliation = cumsum(total_daily_reconciliation)
    total_effective_payment = cumulative_total_flat_rate .+ cumulative_total_reconciliation
    
    # Calculate the system-wide sum (should be zero)
    system_payment_allocation_sum = cumulative_total_allocation .+ total_effective_payment
    
    subplot_index = length(clients) + 1
    plot!(p_combined[subplot_index], daily_time_axis, cumulative_total_flat_rate,
          label="Total Flat Rate Payments",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="System Total: Payment Flow with Reconciliation",
          xlabel="Date",
          ylabel="Total Cumulative Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined[subplot_index], daily_time_axis, cumulative_total_allocation,
          label="Total Allocated Income",
          linewidth=2,
          color=:blue)

    plot!(p_combined[subplot_index], daily_time_axis, cumulative_total_reconciliation,
          label="Cumulative Net Position",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    #plot!(p_combined[subplot_index], daily_time_axis, cumulative_total_reconciliation,
    #      label="Total Reconciliation Adjustments",
    #      linewidth=2,
    #      color=:orange,
    #      linestyle=:dot)
    
    # Add the system-wide difference line
    plot!(p_combined[subplot_index], daily_time_axis, total_effective_payment,
          label="Total Effective Payment",
          linewidth=2,
          color=:purple,
          linestyle=:solid,
          alpha=0.7)
    
    # Calculate and display the final sum (should be near zero)
    final_sum = cumulative_total_allocation[end] + total_effective_payment[end]
    println("Final system balance (allocated income + payment): $(round(final_sum, digits=2)) EUR")
    println("Final balance as percentage: $(round(abs(final_sum)/abs(cumulative_total_allocation[end])*100, digits=4))%")
    
    # Add horizontal line at zero for reference
    hline!(p_combined[subplot_index], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_combined)
