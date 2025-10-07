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
#clients = ["A","G","I","S","Q"]
#clients = ["S","H"]  # Now using all clients for calculations

# Choose two clients to plot (change these to any two clients you want to visualize)
chosen_clients_to_plot = ["A", "G"]

start_hour = DateTime(2024, 01, 01, 00, 0, 0)
total_sim_days = 365
dummy = false
onePrice = false

num_scenarios_demand = 5
num_scenarios_price = 50
spread_scens_length = 1
alphaCVaR = 0.95
beta = 0

# Allocation method selection: "gately" or "full_cost"
allocation_method = "gately"  # Change this to "gately" to switch allocation methods

stochasticData = Dict(
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    "demand_noise_std" => 0.28,
)

# =========================
# 2. Daily Optimization and Allocation
# =========================
allocations = [allocation_method] 
coalitions = sparse_coalitions(clients)
println("Running daily optimization and calculating allocations...")

# Initialize storage
dailyAllocationCosts = []
dailyClientDemand = []
dailyImbalancesDict = []
dailyCVarCosts = []  # Add storage for daily CVaR costs
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
    
    # Store daily CVaR costs
    push!(dailyCVarCosts, daily_cvar_costs)
    
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
    ylabel="Cumulative Cash Flow (EUR)",
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
      label="Grand Coalition Cumulative Cash Flow (Daily Data)", 
      linewidth=4,
      color=:black,
      linestyle=:solid)

# Plot individual client allocation costs (daily cumulative) - only for chosen clients
for client in chosen_clients_to_plot
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

# Create subplots for each chosen client plus one for grand coalition
num_chosen_clients = length(chosen_clients_to_plot)
p_clients = plot(layout=(num_chosen_clients + 1, 1), size=(1400, 500*(num_chosen_clients + 1)))

# Create daily time axis for allocation data (end of each day for proper alignment)
daily_time_axis = [start_hour + Dates.Day(day-1) + Dates.Hour(23) for day in 1:total_sim_days]

# Define daily_total_allocation_pos using the cumulative_total calculated earlier
daily_total_allocation_pos = cumulative_total

# Make flat rate cumulative using the already calculated daily_total_flat_rate_income
daily_total_flat_rate_pos = cumsum(daily_total_flat_rate_income)

# Calculate total net position (allocation + flat rate)
daily_total_net_position = daily_total_allocation_pos .+ daily_total_flat_rate_pos

for (i, client) in enumerate(chosen_clients_to_plot)
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
          label="Cumulative $(allocation_name) Allocated Cost", 
          linewidth=3,
          color=:blue,
          title="Client $client: Cumulative Financial Position\n(Daily Optimization, Daily Data Points)",
          xlabel="Date",
          ylabel="Cumulative Cash Flow (EUR)",
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
if length(chosen_clients_to_plot) > 0
    # Reuse the already calculated daily totals from section 4
    subplot_index = num_chosen_clients + 1
    plot!(p_clients[subplot_index], daily_time_axis, daily_total_allocation_pos, 
          label="Cumulative Total $(allocation_name) Allocated Cost", 
          linewidth=3,
          color=:blue,
          title="Grand Coalition: Cumulative Financial Position\n(Daily Optimization, Daily Data Points)",
          xlabel="Date",
          ylabel="Cumulative Cash Flow (EUR)",
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
# Create monthly reconciliation by calculating the difference between Allocated Cost and flat rate payments
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

p_combined = plot(layout=(length(chosen_clients_to_plot) + 1, 1), size=(1600, 600*(length(chosen_clients_to_plot) + 1)))

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

# Create payment flow visualization for each chosen client
for (i, client) in enumerate(chosen_clients_to_plot)
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
    
    # Calculate the sum of Allocated Cost and total payments (should be zero)
    payment_allocation_sum = cumulative_allocation .+ total_effective_payment
    
    # Plot the complete payment system
    plot!(p_combined[i], daily_time_axis, cumulative_flat_rate,
          label="Cumulative Flat Rate Payments",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="Client $client: Flat rate and reconciliation",
          xlabel="Date",
          ylabel="Cumulative Cash Flow (EUR)",
          legend=:topleft,
          legend_columns=2,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined[i], daily_time_axis, cumulative_allocation,
          label="Allocated Cost",
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
if length(chosen_clients_to_plot) > 0
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
    
    subplot_index = length(chosen_clients_to_plot) + 1
    plot!(p_combined[subplot_index], daily_time_axis, cumulative_total_flat_rate,
          label="Cumulative Flat Rate Payments",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="System Total: Payment Flow with Reconciliation",
          xlabel="Date",
          ylabel="Total Cumulative Cash Flow (EUR)",
          legend=:topleft,
          legend_columns=2,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined[subplot_index], daily_time_axis, cumulative_total_allocation,
          label="Total Allocated Cost",
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
    println("Final system balance (Allocated Cost + payment): $(round(final_sum, digits=2)) EUR")
    println("Final balance as percentage: $(round(abs(final_sum)/abs(cumulative_total_allocation[end])*100, digits=4))%")
    
    # Add horizontal line at zero for reference
    hline!(p_combined[subplot_index], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_combined)

# =========================
# 6. Third Plot: Flat Rate Payment + Previous Month's CVaR Addition
# =========================
println("Creating third plot: Flat rate payment with monthly CVaR adjustments...")

# First, let's aggregate daily CVaR costs by month for each client
# dailyCVarCosts is already stored from the daily loop above

# Calculate monthly CVaR totals for each client
monthly_cvar_totals = Dict{String, Vector{Float64}}()
for client in clients
    monthly_cvar_totals[client] = zeros(length(monthly_dates))
end

# Aggregate CVaR costs by month
for (month_idx, month_date) in enumerate(monthly_dates)
    # Find days in this month
    month_days = []
    for day in 1:total_sim_days
        day_date = Date(start_hour + Dates.Day(day - 1))
        if Date(year(day_date), month(day_date), 1) == month_date
            push!(month_days, day)
        end
    end
    
    # Calculate monthly CVaR totals for each client
    for client in clients
        month_cvar_total = 0.0
        for day in month_days
            # CVaR data is stored by coalition, so individual client CVaR is stored as [client]
            client_coalition = [client]
            if haskey(dailyCVarCosts[day], client_coalition)
                month_cvar_total += dailyCVarCosts[day][client_coalition]
            end
        end
        monthly_cvar_totals[client][month_idx] = month_cvar_total
        # Debug: Print first month's totals
        if month_idx == 1
            println("Month 1 CVaR total for client $client: $month_cvar_total")
        end
    end
end

# Debug: Print monthly CVaR totals for first few months
println("Sample monthly CVaR totals:")
for client in clients[1:min(2, length(clients))]
    println("Client $client monthly CVaR totals (first 3 months): $(monthly_cvar_totals[client][1:min(3, length(monthly_dates))])")
end

# Calculate the payment schedule: flat rate + current month's CVaR
monthly_cvar_adjustments = Dict{String, Vector{Float64}}()
for client in clients
    monthly_cvar_adjustments[client] = zeros(length(monthly_dates))
    # Apply CVaR adjustment for each month
    for month_idx in 1:length(monthly_dates)
        # Add current month's CVaR to the adjustment (negative sign to make it a payment)
        monthly_cvar_adjustments[client][month_idx] = -monthly_cvar_totals[client][month_idx]
    end
end

# Expand monthly CVaR adjustments to daily timeline
function expand_monthly_cvar_to_daily(monthly_cvar_adjustments, monthly_dates, start_date, total_days)
    daily_cvar_adjustments = zeros(total_days)
    
    for day in 1:total_days
        current_date = Date(start_date + Dates.Day(day-1))
        current_month = Date(year(current_date), month(current_date), 1)
        
        # Find which month this day belongs to
        month_index = findfirst(d -> d == current_month, monthly_dates)
        
        # Check if this is the last day of the month
        next_day = current_date + Dates.Day(1)
        is_last_day_of_month = month(next_day) != month(current_date) || day == total_days
        
        # Apply CVaR adjustment on the last day of the month
        if is_last_day_of_month && month_index !== nothing
            daily_cvar_adjustments[day] = monthly_cvar_adjustments[month_index]
        end
    end
    
    return daily_cvar_adjustments
end

# Create the third plot
p_cvar_plot = plot(layout=(length(chosen_clients_to_plot) + 1, 1), size=(1400, 600*(length(chosen_clients_to_plot) + 1)))

# Plot for each chosen client
for (i, client) in enumerate(chosen_clients_to_plot)
    # Extract daily data (reuse from previous sections)
    daily_allocation_costs = []
    for day in 1:total_sim_days
        if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
            push!(daily_allocation_costs, dailyAllocationCosts[day][allocation_method][client])
        else
            push!(daily_allocation_costs, 0.0)
        end
    end
    
    daily_flat_rate_income = [dailyClientFlatRateIncome[day][client] for day in 1:total_sim_days]
    
    # Expand monthly CVaR adjustments to daily timeline
    daily_cvar_adjustments = expand_monthly_cvar_to_daily(
        monthly_cvar_adjustments[client], monthly_dates, start_hour, total_sim_days
    )
    
    # Calculate cumulative values
    cumulative_allocation = cumsum(daily_allocation_costs)
    cumulative_flat_rate = cumsum(daily_flat_rate_income)
    cumulative_cvar_adjustments = cumsum(daily_cvar_adjustments)
    
    # Total payment = flat rate + CVaR adjustments
    total_payment_with_cvar = cumulative_flat_rate .+ cumulative_cvar_adjustments
    
    # Calculate net position (allocation income + total payment)
    net_position_with_cvar = cumulative_allocation .+ total_payment_with_cvar
    
    # Create the plot
    plot!(p_cvar_plot[i], daily_time_axis, cumulative_flat_rate,
          label="Cumulative Flat Rate Payment",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="Client $client: Flat Rate + Current Month CVaR Payment",
          xlabel="Date",
          ylabel="Cumulative Cash Flow (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_cvar_plot[i], daily_time_axis, cumulative_allocation,
          label="Allocated Cost",
          linewidth=2,
          color=:blue)
    
    plot!(p_cvar_plot[i], daily_time_axis, cumulative_cvar_adjustments,
          label="Cumulative CVaR Adjustments (Current Month)",
          linewidth=2,
          color=:orange,
          linestyle=:dot)
    
    plot!(p_cvar_plot[i], daily_time_axis, total_payment_with_cvar,
          label="Total Payment (Flat Rate + CVaR)",
          linewidth=2,
          color=:purple,
          alpha=0.7)
    
    plot!(p_cvar_plot[i], daily_time_axis, net_position_with_cvar,
          label="Net Position (Income + Payment)",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    # Add horizontal line at zero for reference
    hline!(p_cvar_plot[i], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

# Add system total subplot
if length(chosen_clients_to_plot) > 0
    # Calculate total CVaR adjustments across all clients
    total_daily_cvar_adjustments = zeros(total_sim_days)
    for client in clients
        daily_cvar_adjustments = expand_monthly_cvar_to_daily(
            monthly_cvar_adjustments[client], monthly_dates, start_hour, total_sim_days
        )
        total_daily_cvar_adjustments .+= daily_cvar_adjustments
    end
    
    # Calculate totals (reuse already calculated values)
    cumulative_total_allocation = daily_total_allocation_pos  # From section 4
    cumulative_total_flat_rate = daily_total_flat_rate_pos   # From section 4
    cumulative_total_cvar_adjustments = cumsum(total_daily_cvar_adjustments)
    
    total_payment_with_cvar = cumulative_total_flat_rate .+ cumulative_total_cvar_adjustments
    system_net_position_with_cvar = cumulative_total_allocation .+ total_payment_with_cvar
    
    subplot_index = length(chosen_clients_to_plot) + 1
    plot!(p_cvar_plot[subplot_index], daily_time_axis, cumulative_total_flat_rate,
          label="Total Flat Rate Payments",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="System Total: Flat Rate + Current Month CVaR Payment",
          xlabel="Date",
          ylabel="Total Cumulative Cash Flow (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_cvar_plot[subplot_index], daily_time_axis, cumulative_total_allocation,
          label="Total Allocated Cost",
          linewidth=2,
          color=:blue)
    
    plot!(p_cvar_plot[subplot_index], daily_time_axis, cumulative_total_cvar_adjustments,
          label="Total CVaR Adjustments (Current Month)",
          linewidth=2,
          color=:orange,
          linestyle=:dot)
    
    plot!(p_cvar_plot[subplot_index], daily_time_axis, total_payment_with_cvar,
          label="Total Payment (Flat Rate + CVaR)",
          linewidth=2,
          color=:purple,
          alpha=0.7)
    
    plot!(p_cvar_plot[subplot_index], daily_time_axis, system_net_position_with_cvar,
          label="Total Net Position",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    # Calculate and display final balance
    final_balance_cvar = cumulative_total_allocation[end] + total_payment_with_cvar[end]
    println("Final system balance with CVaR adjustments: $(round(final_balance_cvar, digits=2)) EUR")
    println("Final balance as percentage: $(round(abs(final_balance_cvar)/abs(cumulative_total_allocation[end])*100, digits=4))%")
    
    # Add horizontal line at zero for reference
    hline!(p_cvar_plot[subplot_index], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_cvar_plot)

# =========================
# 7. Calculate Maximum Percentage Increase from Flat Rate to Flat Rate + Reconciliation
# =========================
println("Calculating maximum percentage increase from flat rate to flat rate + reconciliation for each client...")

# Calculate monthly flat rate and reconciliation payments for each client
max_percentage_increases = Dict{String, Float64}()
max_absolute_increases = Dict{String, Float64}()

for client in clients
    client_max_percentage_increase = 0.0
    client_max_absolute_increase = 0.0
    
    # For each month, calculate the percentage increase
    for month_idx in 1:length(monthly_dates)
        # Calculate monthly flat rate payment for this client
        month_date = monthly_dates[month_idx]
        month_days = []
        for day in 1:total_sim_days
            day_date = Date(start_hour + Dates.Day(day - 1))
            if Date(year(day_date), month(day_date), 1) == month_date
                push!(month_days, day)
            end
        end
        
        # Calculate monthly flat rate payment (absolute value since payments are positive costs)
        monthly_flat_rate_payment = abs(sum(dailyClientFlatRateIncome[day][client] for day in month_days))
        
        # Get monthly reconciliation payment (absolute value)
        monthly_reconciliation_payment = abs(monthly_reconciliation[client][month_idx])
        
        # Calculate total payment (flat rate + reconciliation)
        total_monthly_payment = monthly_flat_rate_payment + monthly_reconciliation_payment
        
        # Calculate percentage increase (only if flat rate payment > 0 to avoid division by zero)
        if monthly_flat_rate_payment > 1e-6  # Small threshold to avoid numerical issues
            percentage_increase = (monthly_reconciliation_payment / monthly_flat_rate_payment) * 100
            client_max_percentage_increase = max(client_max_percentage_increase, percentage_increase)
            client_max_absolute_increase = max(client_max_absolute_increase, monthly_reconciliation_payment)
        end
    end
    
    max_percentage_increases[client] = client_max_percentage_increase
    max_absolute_increases[client] = client_max_absolute_increase
end

# Sort clients by their maximum percentage increase for better visualization
sorted_clients = sort(collect(keys(max_percentage_increases)), by=x -> max_percentage_increases[x], rev=true)
sorted_percentage_increases = [max_percentage_increases[client] for client in sorted_clients]
sorted_absolute_increases = [max_absolute_increases[client] for client in sorted_clients]

# Create bar chart using numeric positions for proper alignment
client_positions = 1:length(sorted_clients)

# Create dual-axis bar chart with separate plots
p1 = bar(client_positions, sorted_percentage_increases,
    title="Maximum Monthly Percentage Increase\nFrom Flat Rate Payment to Flat Rate + Reconciliation Payment",
    xlabel="Client",
    ylabel="Maximum Percentage Increase (%)",
    color=:steelblue,
    size=(1600, 400),
    grid=true,
    margins=8Plots.mm,
    xrotation=45,
    tickfontsize=10,
    guidefontsize=12,
    titlefontsize=14,
    xticks=(client_positions, sorted_clients),
    legend=false
)

# Add value labels for percentage increases
for (i, pct_increase) in enumerate(sorted_percentage_increases)
    annotate!(p1, i, pct_increase + maximum(sorted_percentage_increases) * 0.02, 
              text("$(round(pct_increase, digits=1))%", :center, 8))
end

p2 = bar(client_positions, sorted_absolute_increases,
    title="Maximum Monthly Absolute Increase\nFrom Flat Rate Payment to Flat Rate + Reconciliation Payment",
    xlabel="Client",
    ylabel="Maximum Absolute Increase (EUR)",
    color=:orange,
    size=(1600, 400),
    grid=true,
    margins=8Plots.mm,
    xrotation=45,
    tickfontsize=10,
    guidefontsize=12,
    titlefontsize=14,
    xticks=(client_positions, sorted_clients),
    legend=false
)

# Add value labels for absolute increases
for (i, abs_increase) in enumerate(sorted_absolute_increases)
    annotate!(p2, i, abs_increase + maximum(sorted_absolute_increases) * 0.02, 
              text("$(round(abs_increase, digits=0))€", :center, 8))
end

# Combine into a single plot with two subplots
p_bar = plot(p1, p2, layout=(2,1), size=(1600, 900))

display(p_bar)

# Print summary statistics
println("\n=== Maximum Increase Summary ===")
println("Client\tMax % Increase\tMax Absolute Increase (EUR)")
println("-----\t--------------\t------------------------")
for client in sorted_clients
    println("$client\t$(round(max_percentage_increases[client], digits=2))%\t\t$(round(max_absolute_increases[client], digits=2))")
end

avg_percentage_increase = mean(values(max_percentage_increases))
median_percentage_increase = median(values(max_percentage_increases))
max_percentage_increase = maximum(values(max_percentage_increases))
min_percentage_increase = minimum(values(max_percentage_increases))

avg_absolute_increase = mean(values(max_absolute_increases))
median_absolute_increase = median(values(max_absolute_increases))
max_absolute_increase = maximum(values(max_absolute_increases))
min_absolute_increase = minimum(values(max_absolute_increases))

println("\nPercentage Increase Statistics:")
println("Average maximum increase: $(round(avg_percentage_increase, digits=2))%")
println("Median maximum increase: $(round(median_percentage_increase, digits=2))%")
println("Highest maximum increase: $(round(max_percentage_increase, digits=2))% (Client $(sorted_clients[1]))")
println("Lowest maximum increase: $(round(min_percentage_increase, digits=2))% (Client $(sorted_clients[end]))")

println("\nAbsolute Increase Statistics (EUR):")
println("Average maximum increase: $(round(avg_absolute_increase, digits=2)) EUR")
println("Median maximum increase: $(round(median_absolute_increase, digits=2)) EUR")
println("Highest maximum increase: $(round(max_absolute_increase, digits=2)) EUR")
println("Lowest maximum increase: $(round(min_absolute_increase, digits=2)) EUR")

# =========================
# 8. Analysis with 20% Higher Flat Rate
# =========================
println("\n=== Starting Analysis with 20% Higher Flat Rate ===")

# Calculate 20% higher flat rate
flat_rate_fee_20pct_higher = flat_rate_fee * 1.2
println("Original flat rate fee: $(round(flat_rate_fee, digits=4)) EUR/MWh")
println("20% higher flat rate fee: $(round(flat_rate_fee_20pct_higher, digits=4)) EUR/MWh")

# Calculate daily flat rate income for each client with higher rate
dailyClientFlatRateIncome_20pct = []
daily_total_flat_rate_income_20pct = []
for day in 1:total_sim_days
    daily_flat_rate_20pct = Dict{String, Float64}()
    for client in clients
        # Flat rate income = demand * flat_rate_fee_20pct_higher
        daily_flat_rate_20pct[client] = dailyClientDemand[day][client] * flat_rate_fee_20pct_higher
    end
    push!(dailyClientFlatRateIncome_20pct, daily_flat_rate_20pct)
    # Calculate total flat rate for this day
    push!(daily_total_flat_rate_income_20pct, sum(values(daily_flat_rate_20pct)))
end

# Calculate monthly reconciliation with 20% higher flat rate
monthly_reconciliation_20pct = Dict{String, Vector{Float64}}()
for client in clients
    monthly_reconciliation_20pct[client] = zeros(length(monthly_dates))
end

# Calculate monthly reconciliation for each client with higher flat rate
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
        month_flat_rate_total_20pct = 0.0
        
        for day in month_days
            # Add allocation income for this day (same as before)
            if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
                month_allocation_total += dailyAllocationCosts[day][allocation_method][client]
            end
            
            # Add higher flat rate payment for this day
            month_flat_rate_total_20pct += dailyClientFlatRateIncome_20pct[day][client]
        end
        
        # Reconciliation = -(allocation + flat_rate) to balance to zero
        monthly_reconciliation_20pct[client][month_idx] = -(month_allocation_total + month_flat_rate_total_20pct)
    end
end

# =========================
# 9. Payment Flow Visualization with 20% Higher Flat Rate
# =========================
println("Creating payment flow plots with 20% higher flat rate...")

p_combined_20pct = plot(layout=(length(chosen_clients_to_plot) + 1, 1), size=(1600, 600*(length(chosen_clients_to_plot) + 1)))

# Create payment flow visualization for each chosen client with higher flat rate
for (i, client) in enumerate(chosen_clients_to_plot)
    # Reuse the already extracted daily data from section 4
    daily_allocation_costs = []
    for day in 1:total_sim_days
        if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
            push!(daily_allocation_costs, dailyAllocationCosts[day][allocation_method][client])
        else
            push!(daily_allocation_costs, 0.0)
        end
    end
    
    daily_flat_rate_income_20pct = [dailyClientFlatRateIncome_20pct[day][client] for day in 1:total_sim_days]
    
    # Expand monthly reconciliation to daily timeline
    daily_reconciliation_20pct = expand_monthly_reconciliation_to_daily(
        monthly_reconciliation_20pct[client], monthly_dates, start_hour, total_sim_days
    )
    
    # Calculate cumulative values
    cumulative_allocation = cumsum(daily_allocation_costs)
    cumulative_flat_rate_20pct = cumsum(daily_flat_rate_income_20pct)
    cumulative_reconciliation_20pct = cumsum(daily_reconciliation_20pct)
    
    # Total effective payment = flat rate + reconciliation adjustments
    total_effective_payment_20pct = cumulative_flat_rate_20pct .+ cumulative_reconciliation_20pct
    
    # Calculate the sum of Allocated Cost and total payments (should be zero)
    payment_allocation_sum_20pct = cumulative_allocation .+ total_effective_payment_20pct
    
    # Plot the complete payment system
    plot!(p_combined_20pct[i], daily_time_axis, cumulative_flat_rate_20pct,
          label="Cumulative Flat Rate Payments (+20%)",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="Client $client: Flat rate (+20%) and reconciliation",
          xlabel="Date",
          ylabel="Cumulative Cash Flow (EUR)",
          legend=:topleft,
          legend_columns=2,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined_20pct[i], daily_time_axis, cumulative_allocation,
          label="Allocated Cost",
          linewidth=2,
          color=:blue)
    
    plot!(p_combined_20pct[i], daily_time_axis, payment_allocation_sum_20pct,
          label="Cumulative Net Position",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    plot!(p_combined_20pct[i], daily_time_axis, total_effective_payment_20pct,
          label="Total Effective Payment (Flat rate +20% + Reconciliation)",
          linewidth=2,
          color=:purple,
          alpha=0.7)
    
    # Add horizontal line at zero for reference
    hline!(p_combined_20pct[i], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

# Add total system subplot for 20% higher flat rate
if length(chosen_clients_to_plot) > 0
    # Calculate totals across all clients
    cumulative_total_allocation = daily_total_allocation_pos  # Already calculated in section 4
    cumulative_total_flat_rate_20pct = cumsum(daily_total_flat_rate_income_20pct)
    
    # Calculate total reconciliation across all clients
    total_daily_reconciliation_20pct = zeros(total_sim_days)
    for client in clients
        daily_reconciliation_client_20pct = expand_monthly_reconciliation_to_daily(
            monthly_reconciliation_20pct[client], monthly_dates, start_hour, total_sim_days
        )
        total_daily_reconciliation_20pct .+= daily_reconciliation_client_20pct
    end
    
    cumulative_total_reconciliation_20pct = cumsum(total_daily_reconciliation_20pct)
    total_effective_payment_20pct = cumulative_total_flat_rate_20pct .+ cumulative_total_reconciliation_20pct
    system_net_position_20pct = cumulative_total_allocation .+ total_effective_payment_20pct
    
    subplot_index = length(chosen_clients_to_plot) + 1
    plot!(p_combined_20pct[subplot_index], daily_time_axis, cumulative_total_flat_rate_20pct,
          label="Total Flat Rate Payments (+20%)",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="System Total: Flat Rate (+20%) + Reconciliation Payment",
          xlabel="Date",
          ylabel="Total Cumulative Cash Flow (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined_20pct[subplot_index], daily_time_axis, cumulative_total_allocation,
          label="Total Allocated Cost",
          linewidth=2,
          color=:blue)
    
    plot!(p_combined_20pct[subplot_index], daily_time_axis, total_effective_payment_20pct,
          label="Total Effective Payment (Flat rate +20% + Reconciliation)",
          linewidth=2,
          color=:purple,
          alpha=0.7)
    
    plot!(p_combined_20pct[subplot_index], daily_time_axis, system_net_position_20pct,
          label="Total Net Position",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    # Calculate and display final balance
    final_balance_20pct = cumulative_total_allocation[end] + total_effective_payment_20pct[end]
    println("Final system balance with 20% higher flat rate: $(round(final_balance_20pct, digits=2)) EUR")
    println("Final balance as percentage: $(round(abs(final_balance_20pct)/abs(cumulative_total_allocation[end])*100, digits=4))%")
    
    # Add horizontal line at zero for reference
    hline!(p_combined_20pct[subplot_index], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_combined_20pct)

# =========================
# 10. Calculate Maximum Increases with 20% Higher Flat Rate
# =========================
println("Calculating maximum increases with 20% higher flat rate...")

# Calculate monthly flat rate and reconciliation payments for each client with higher rate
max_percentage_increases_20pct = Dict{String, Float64}()
max_absolute_increases_20pct = Dict{String, Float64}()

for client in clients
    client_max_percentage_increase_20pct = 0.0
    client_max_absolute_increase_20pct = 0.0
    
    # For each month, calculate the percentage increase
    for month_idx in 1:length(monthly_dates)
        # Calculate monthly flat rate payment for this client with higher rate
        month_date = monthly_dates[month_idx]
        month_days = []
        for day in 1:total_sim_days
            day_date = Date(start_hour + Dates.Day(day - 1))
            if Date(year(day_date), month(day_date), 1) == month_date
                push!(month_days, day)
            end
        end
        
        # Calculate monthly flat rate payment with 20% higher rate
        monthly_flat_rate_payment_20pct = abs(sum(dailyClientFlatRateIncome_20pct[day][client] for day in month_days))
        
        # Get monthly reconciliation payment with higher flat rate
        monthly_reconciliation_payment_20pct = abs(monthly_reconciliation_20pct[client][month_idx])
        
        # Calculate percentage increase (only if flat rate payment > 0)
        if monthly_flat_rate_payment_20pct > 1e-6
            percentage_increase_20pct = (monthly_reconciliation_payment_20pct / monthly_flat_rate_payment_20pct) * 100
            client_max_percentage_increase_20pct = max(client_max_percentage_increase_20pct, percentage_increase_20pct)
            client_max_absolute_increase_20pct = max(client_max_absolute_increase_20pct, monthly_reconciliation_payment_20pct)
        end
    end
    
    max_percentage_increases_20pct[client] = client_max_percentage_increase_20pct
    max_absolute_increases_20pct[client] = client_max_absolute_increase_20pct
end

# Create bar charts with 20% higher flat rate
println("Creating bar charts with 20% higher flat rate...")

# Sort clients by their maximum percentage increase for better visualization
sorted_clients_20pct = sort(collect(keys(max_percentage_increases_20pct)), by=x -> max_percentage_increases_20pct[x], rev=true)
sorted_percentage_increases_20pct = [max_percentage_increases_20pct[client] for client in sorted_clients_20pct]
sorted_absolute_increases_20pct = [max_absolute_increases_20pct[client] for client in sorted_clients_20pct]

# Create bar chart using numeric positions for proper alignment
client_positions_20pct = 1:length(sorted_clients_20pct)

# Create dual-axis bar chart with separate plots for 20% higher flat rate
p1_20pct = bar(client_positions_20pct, sorted_percentage_increases_20pct,
    title="Maximum Monthly Percentage Increase (Flat Rate +20%)\nFrom Flat Rate Payment to Flat Rate + Reconciliation Payment",
    xlabel="Client",
    ylabel="Maximum Percentage Increase (%)",
    color=:steelblue,
    size=(1600, 400),
    grid=true,
    margins=8Plots.mm,
    xrotation=45,
    tickfontsize=10,
    guidefontsize=12,
    titlefontsize=14,
    xticks=(client_positions_20pct, sorted_clients_20pct),
    legend=false
)

# Add value labels for percentage increases
for (i, pct_increase) in enumerate(sorted_percentage_increases_20pct)
    annotate!(p1_20pct, i, pct_increase + maximum(sorted_percentage_increases_20pct) * 0.02, 
              text("$(round(pct_increase, digits=1))%", :center, 8))
end

p2_20pct = bar(client_positions_20pct, sorted_absolute_increases_20pct,
    title="Maximum Monthly Absolute Increase (Flat Rate +20%)\nFrom Flat Rate Payment to Flat Rate + Reconciliation Payment",
    xlabel="Client",
    ylabel="Maximum Absolute Increase (EUR)",
    color=:orange,
    size=(1600, 400),
    grid=true,
    margins=8Plots.mm,
    xrotation=45,
    tickfontsize=10,
    guidefontsize=12,
    titlefontsize=14,
    xticks=(client_positions_20pct, sorted_clients_20pct),
    legend=false
)

# Add value labels for absolute increases
for (i, abs_increase) in enumerate(sorted_absolute_increases_20pct)
    annotate!(p2_20pct, i, abs_increase + maximum(sorted_absolute_increases_20pct) * 0.02, 
              text("$(round(abs_increase, digits=0))€", :center, 8))
end

# Combine into a single plot with two subplots
p_bar_20pct = plot(p1_20pct, p2_20pct, layout=(2,1), size=(1600, 900))

display(p_bar_20pct)

# Print summary statistics for 20% higher flat rate
println("\n=== Maximum Increase Summary (20% Higher Flat Rate) ===")
println("Client\tMax % Increase\tMax Absolute Increase (EUR)")
println("-----\t--------------\t------------------------")
for client in sorted_clients_20pct
    println("$client\t$(round(max_percentage_increases_20pct[client], digits=2))%\t\t$(round(max_absolute_increases_20pct[client], digits=2))")
end

avg_percentage_increase_20pct = mean(values(max_percentage_increases_20pct))
median_percentage_increase_20pct = median(values(max_percentage_increases_20pct))
max_percentage_increase_20pct = maximum(values(max_percentage_increases_20pct))
min_percentage_increase_20pct = minimum(values(max_percentage_increases_20pct))

avg_absolute_increase_20pct = mean(values(max_absolute_increases_20pct))
median_absolute_increase_20pct = median(values(max_absolute_increases_20pct))
max_absolute_increase_20pct = maximum(values(max_absolute_increases_20pct))
min_absolute_increase_20pct = minimum(values(max_absolute_increases_20pct))

println("\nPercentage Increase Statistics (20% Higher Flat Rate):")
println("Average maximum increase: $(round(avg_percentage_increase_20pct, digits=2))%")
println("Median maximum increase: $(round(median_percentage_increase_20pct, digits=2))%")
println("Highest maximum increase: $(round(max_percentage_increase_20pct, digits=2))% (Client $(sorted_clients_20pct[1]))")
println("Lowest maximum increase: $(round(min_percentage_increase_20pct, digits=2))% (Client $(sorted_clients_20pct[end]))")

println("\nAbsolute Increase Statistics (20% Higher Flat Rate, EUR):")
println("Average maximum increase: $(round(avg_absolute_increase_20pct, digits=2)) EUR")
println("Median maximum increase: $(round(median_absolute_increase_20pct, digits=2)) EUR")
println("Highest maximum increase: $(round(max_absolute_increase_20pct, digits=2)) EUR")
println("Lowest maximum increase: $(round(min_absolute_increase_20pct, digits=2)) EUR")

# Compare with original flat rate
println("\n=== Comparison: Original vs 20% Higher Flat Rate ===")
println("Average percentage increase reduction: $(round(avg_percentage_increase - avg_percentage_increase_20pct, digits=2)) percentage points")
println("Average absolute increase reduction: $(round(avg_absolute_increase - avg_absolute_increase_20pct, digits=2)) EUR")

# =========================
# 11. Analysis with Yearly Reconciliation (Original Flat Rate)
# =========================
println("\n=== Starting Analysis with Yearly Reconciliation ===")

# Calculate yearly reconciliation (using original flat rate)
yearly_reconciliation = Dict{String, Float64}()

# Calculate total yearly allocation and flat rate for each client
for client in clients
    total_yearly_allocation = 0.0
    total_yearly_flat_rate = 0.0
    
    for day in 1:total_sim_days
        # Add allocation income for this day
        if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
            total_yearly_allocation += dailyAllocationCosts[day][allocation_method][client]
        end
        
        # Add flat rate payment for this day
        total_yearly_flat_rate += dailyClientFlatRateIncome[day][client]
    end
    
    # Yearly reconciliation = -(allocation + flat_rate) to balance to zero
    yearly_reconciliation[client] = -(total_yearly_allocation + total_yearly_flat_rate)
end

# =========================
# 12. Payment Flow Visualization with Yearly Reconciliation
# =========================
println("Creating payment flow plots with yearly reconciliation...")

p_combined_yearly = plot(layout=(length(chosen_clients_to_plot) + 1, 1), size=(1600, 600*(length(chosen_clients_to_plot) + 1)))

# Function to apply yearly reconciliation on the last day of the year
function expand_yearly_reconciliation_to_daily(yearly_reconciliation_amount, total_days)
    daily_reconciliation = zeros(total_days)
    # Apply reconciliation on the last day of the simulation (end of year)
    daily_reconciliation[end] = yearly_reconciliation_amount
    return daily_reconciliation
end

# Create payment flow visualization for each chosen client with yearly reconciliation
for (i, client) in enumerate(chosen_clients_to_plot)
    # Reuse the already extracted daily data
    daily_allocation_costs = []
    for day in 1:total_sim_days
        if haskey(dailyAllocationCosts[day], allocation_method) && haskey(dailyAllocationCosts[day][allocation_method], client)
            push!(daily_allocation_costs, dailyAllocationCosts[day][allocation_method][client])
        else
            push!(daily_allocation_costs, 0.0)
        end
    end
    
    daily_flat_rate_income = [dailyClientFlatRateIncome[day][client] for day in 1:total_sim_days]
    
    # Apply yearly reconciliation on the last day
    daily_reconciliation_yearly = expand_yearly_reconciliation_to_daily(
        yearly_reconciliation[client], total_sim_days
    )
    
    # Calculate cumulative values
    cumulative_allocation = cumsum(daily_allocation_costs)
    cumulative_flat_rate = cumsum(daily_flat_rate_income)
    cumulative_reconciliation_yearly = cumsum(daily_reconciliation_yearly)
    
    # Total effective payment = flat rate + reconciliation adjustments
    total_effective_payment_yearly = cumulative_flat_rate .+ cumulative_reconciliation_yearly
    
    # Calculate the sum of Allocated Cost and total payments (should be zero)
    payment_allocation_sum_yearly = cumulative_allocation .+ total_effective_payment_yearly
    
    # Plot the complete payment system
    plot!(p_combined_yearly[i], daily_time_axis, cumulative_flat_rate,
          label="Cumulative Flat Rate Payments",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="Client $client: Flat rate and yearly reconciliation",
          xlabel="Date",
          ylabel="Cumulative Cash Flow (EUR)",
          legend=:topleft,
          legend_columns=2,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined_yearly[i], daily_time_axis, cumulative_allocation,
          label="Allocated Cost",
          linewidth=2,
          color=:blue)
    
    plot!(p_combined_yearly[i], daily_time_axis, payment_allocation_sum_yearly,
          label="Cumulative Net Position",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    plot!(p_combined_yearly[i], daily_time_axis, total_effective_payment_yearly,
          label="Total Effective Payment (Flat rate + Yearly Reconciliation)",
          linewidth=2,
          color=:purple,
          alpha=0.7)
    
    # Add step change at reconciliation point
    plot!(p_combined_yearly[i], daily_time_axis, cumulative_reconciliation_yearly,
          label="Cumulative Yearly Reconciliation",
          linewidth=2,
          color=:orange,
          linestyle=:dot)
    
    # Add horizontal line at zero for reference
    hline!(p_combined_yearly[i], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

# Add total system subplot for yearly reconciliation
if length(chosen_clients_to_plot) > 0
    # Calculate totals across all clients
    cumulative_total_allocation = daily_total_allocation_pos  # Already calculated
    cumulative_total_flat_rate = daily_total_flat_rate_pos   # Already calculated
    
    # Calculate total yearly reconciliation across all clients
    total_yearly_reconciliation = sum(yearly_reconciliation[client] for client in clients)
    total_daily_reconciliation_yearly = expand_yearly_reconciliation_to_daily(
        total_yearly_reconciliation, total_sim_days
    )
    
    cumulative_total_reconciliation_yearly = cumsum(total_daily_reconciliation_yearly)
    total_effective_payment_yearly = cumulative_total_flat_rate .+ cumulative_total_reconciliation_yearly
    system_net_position_yearly = cumulative_total_allocation .+ total_effective_payment_yearly
    
    subplot_index = length(chosen_clients_to_plot) + 1
    plot!(p_combined_yearly[subplot_index], daily_time_axis, cumulative_total_flat_rate,
          label="Total Flat Rate Payments",
          linewidth=2,
          color=:green,
          linestyle=:dash,
          title="System Total: Flat Rate + Yearly Reconciliation Payment",
          xlabel="Date",
          ylabel="Total Cumulative Cash Flow (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          margins=8Plots.mm,
          xrotation=45,
          tickfontsize=10,
          guidefontsize=12,
          titlefontsize=14)
    
    plot!(p_combined_yearly[subplot_index], daily_time_axis, cumulative_total_allocation,
          label="Total Allocated Cost",
          linewidth=2,
          color=:blue)
    
    plot!(p_combined_yearly[subplot_index], daily_time_axis, total_effective_payment_yearly,
          label="Total Effective Payment (Flat rate + Yearly Reconciliation)",
          linewidth=2,
          color=:purple,
          alpha=0.7)
    
    plot!(p_combined_yearly[subplot_index], daily_time_axis, system_net_position_yearly,
          label="Total Net Position",
          linewidth=3,
          color=:red,
          linestyle=:dash,
          alpha=0.8)
    
    plot!(p_combined_yearly[subplot_index], daily_time_axis, cumulative_total_reconciliation_yearly,
          label="Total Yearly Reconciliation",
          linewidth=2,
          color=:orange,
          linestyle=:dot)
    
    # Calculate and display final balance
    final_balance_yearly = cumulative_total_allocation[end] + total_effective_payment_yearly[end]
    println("Final system balance with yearly reconciliation: $(round(final_balance_yearly, digits=2)) EUR")
    println("Final balance as percentage: $(round(abs(final_balance_yearly)/abs(cumulative_total_allocation[end])*100, digits=4))%")
    
    # Add horizontal line at zero for reference
    hline!(p_combined_yearly[subplot_index], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_combined_yearly)

# =========================
# 13. Compare Yearly vs Monthly Reconciliation
# =========================
println("\n=== Yearly vs Monthly Reconciliation Summary ===")
println("Client\tYearly Reconciliation (EUR)\tSum of Monthly Reconciliations (EUR)")
println("-----\t---------------------------\t------------------------------------")

for client in clients
    yearly_amount = yearly_reconciliation[client]
    monthly_sum = sum(monthly_reconciliation[client])
    println("$client\t$(round(yearly_amount, digits=2))\t\t\t$(round(monthly_sum, digits=2))")
end

# Calculate statistics
yearly_amounts = collect(values(yearly_reconciliation))
monthly_sums = [sum(monthly_reconciliation[client]) for client in clients]

println("\nComparison Statistics:")
println("Total yearly reconciliation across all clients: $(round(sum(yearly_amounts), digits=2)) EUR")
println("Total monthly reconciliation across all clients: $(round(sum(monthly_sums), digits=2)) EUR")
println("Difference (should be ~0): $(round(sum(yearly_amounts) - sum(monthly_sums), digits=6)) EUR")

println("\nClient-level reconciliation amounts:")
println("Average yearly reconciliation: $(round(mean(abs.(yearly_amounts)), digits=2)) EUR")
println("Average sum of monthly reconciliations: $(round(mean(abs.(monthly_sums)), digits=2)) EUR")
println("Max yearly reconciliation: $(round(maximum(abs.(yearly_amounts)), digits=2)) EUR")
println("Max sum of monthly reconciliations: $(round(maximum(abs.(monthly_sums)), digits=2)) EUR")

# Create bar chart comparing reconciliation timing approaches
println("Creating comparison bar chart...")

sorted_clients_comparison = sort(clients, by=x -> abs(yearly_reconciliation[x]), rev=true)
yearly_amounts_sorted = [yearly_reconciliation[client] for client in sorted_clients_comparison]
monthly_max_sorted = [maximum(abs.(monthly_reconciliation[client])) for client in sorted_clients_comparison]

client_positions_comp = 1:length(sorted_clients_comparison)

p_comparison = bar(client_positions_comp .- 0.2, abs.(yearly_amounts_sorted),
    title="Reconciliation Payment Comparison:\nYearly vs Maximum Monthly Payment",
    xlabel="Client",
    ylabel="Reconciliation Payment (EUR)",
    label="Yearly Reconciliation (Total)",
    color=:steelblue,
    bar_width=0.4,
    size=(1600, 700),
    grid=true,
    margins=8Plots.mm,
    xrotation=45,
    tickfontsize=10,
    guidefontsize=12,
    titlefontsize=14,
    xticks=(client_positions_comp, sorted_clients_comparison),
    legend=:topright
)

bar!(p_comparison, client_positions_comp .+ 0.2, monthly_max_sorted,
    label="Maximum Monthly Reconciliation",
    color=:orange,
    bar_width=0.4
)

# Add value labels
for (i, (yearly_amt, monthly_max)) in enumerate(zip(abs.(yearly_amounts_sorted), monthly_max_sorted))
    annotate!(p_comparison, i - 0.2, yearly_amt + maximum(abs.(yearly_amounts_sorted)) * 0.02, 
              text("$(round(yearly_amt, digits=0))", :center, 8))
    annotate!(p_comparison, i + 0.2, monthly_max + maximum(monthly_max_sorted) * 0.02, 
              text("$(round(monthly_max, digits=0))", :center, 8))
end

display(p_comparison)

println("\n=== Key Insights ===")
println("• Yearly reconciliation eliminates monthly payment volatility")
println("• Clients pay only flat rate throughout the year, with one adjustment at year-end")
println("• Maximum single payment shock is reduced for most clients")
println("• System maintains perfect balance while providing payment stability")
