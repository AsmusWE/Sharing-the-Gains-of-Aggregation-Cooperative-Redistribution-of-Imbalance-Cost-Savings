# This code simulates monthly costs and plots the cost to the BRP and clients
# --- Project Modules ---
include("../Data_import.jl")
include("../Scenario_creation.jl")
include("../Imbalance_functions.jl")
include("../Game_theoretic_functions.jl")
include("../Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, Serialization #,StatsPlots
GC.gc() # Run garbage collection to free memory, useful for repeat runs

Random.seed!(1) # Set seed for reproducibility

# Define a struct to hold all relevant plotting data
struct SimplePlotData
    allocations::Vector{String}
    systemData::Dict{String, Any}
    allocationCosts::Dict{String, Any}
    coalitionCosts::Dict{Any, Any}
    imbalancesDict::Dict{Any, Any}
    clients::Vector{String}
    start_hour::DateTime
    sim_days::Int
end

# =========================
# 1. Data Loading & Setup
# =========================
# Choose filename of saved data
FileName = "temp.jls"

# Choose which allocations to calculate
allocations = [
    #"shapley",
    "VCG",
    #"VCG_budget_balanced",
    "gately",
    #"gately_interval",
    #"full_cost", # Uniform price for cost
    #"reduced_cost",
    #"nucleolus",
    #"flat_rate",
    #"cost_based" # Uniform price for CVaR
]


systemData, clients, demandData = load_data()# Filter out smallest clients for full plot all coalitions, down from 22 to 19
clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)
clients = ["A","G","I","S","Q"]

start_hour = DateTime(2023, 11, 01, 00, 0, 0)
simulation_months = 12
month_length = 30 # Days in a month

num_scenarios_demand = 3 # Number of scenarios for demand
num_scenarios_price = 20 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
alphaCVaR = 0.025 # CVaR confidence level
beta = 0.5 # Weighting factor between cost and CVaR in total cost calculation

stochasticData = Dict(
    # Accepted forecast types demand: "perfect", "scenarios", "noise"
    # Accepted forecast types PV: "perfect", "scenarios"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    "demand_noise_std" => 0.28,
)



# =========================
# 2. Imbalance Calculation and allocation
# =========================
# Remove allocation methods that are not suitable for cost+CVaR yet
allocations = filter(x -> !(x in ["full_cost", "reduced_cost", "gately_interval"]), allocations)
# Remove allocation methods that do not work with the simple calculations 
allocations = filter(x -> !(x in ["shapley", "nucleolus"]), allocations)
coalitions = sparse_coalitions(clients)
println("Calculating total costs (regular costs + CVaR) for simple plot...")
monthlyClientImbalanceCosts = []
monthlyClientCVaRCosts = []
monthlyClientDemand = []
monthlyAllocationCosts = []
monthlyGrandCoalitionCosts = []
for month in 1:simulation_months
    println("Calculating month ", month, " of ", simulation_months)
    monthData = set_period!(deepcopy(systemData), start_hour + Dates.Day((month-1)*month_length), month_length)
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, simulation_months*month_length; num_scenarios=num_scenarios_demand)
    stochasticData["imbalance_spread"], stochasticData["spot_price"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
    stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])
    #monthDataStochastic = set_period!(stochasticData, start_hour + Dates.Day((month-1)*month_length), month_length)
    sim_days = month_length
    totalCostsDict, costsDict, cvarDict, imbalancesDict = @time calculate_total_costs_specific(
        monthData, coalitions, stochasticData, sim_days; alpha=alphaCVaR, beta = beta
    )

    allocation_costs = calculate_allocations(
        allocations, clients, totalCostsDict, imbalancesDict, monthData; printing = true, alpha=alphaCVaR
    )
    push!(monthlyClientImbalanceCosts, costsDict)
    push!(monthlyClientCVaRCosts, cvarDict)
    push!(monthlyAllocationCosts, allocation_costs)
    push!(monthlyGrandCoalitionCosts, totalCostsDict[clients])

    clientDemand = Dict()
    for client in clients
        clientDemand[client] = sum(monthData["price_prod_demand_df"][!, client])
    end
    push!(monthlyClientDemand, clientDemand)

end


# Plot of income with flat MWh fee per client
flat_rate_fee = 10 # EUR/MWh
monthlyClientFlatRateIncome = []
for month in 1:simulation_months
    client_income = Dict()
    for client in clients
        client_income[client] = monthlyClientDemand[month][client] * flat_rate_fee
    end
    push!(monthlyClientFlatRateIncome, client_income)
end

# =========================
# CVaR-based Payment Calculation
# =========================
# Create payments based on previous month's CVaR (use flat rate for first month)
monthlyClientCVaRPayments = []
for month in 1:simulation_months
    client_cvar_payments = Dict()
    for client in clients
        client_cvar_payments[client] = 2*monthlyClientCVaRCosts[month][[client]] # Default to current month's CVaR cost
    end
    #if month == 1
    #    # Use flat rate for the first month
    #    for client in clients
    #        client_cvar_payments[client] = monthlyClientDemand[month][client] * flat_rate_fee
    #    end
    #else
    #    # Use previous month's CVaR costs as payment rate
    #    prev_month_cvar = monthlyClientCVaRCosts[month-1]
    #    prev_month_demand = monthlyClientDemand[month-1]
    #    
    #    for client in clients
    #            cvar_rate = prev_month_cvar[[client]] / prev_month_demand[client]  # EUR/MWh
    #            client_cvar_payments[client] = monthlyClientDemand[month][client] * cvar_rate
    #    end
    #end
    
    push!(monthlyClientCVaRPayments, client_cvar_payments)
end

# =========================
# 3. Plot Monthly Grand Coalition and Gately Allocation Costs
# =========================
println("Creating combined monthly costs plot...")

# Initialize plot
p = plot(
    title="Monthly Grand Coalition vs Individual Gately Allocation Costs",
    xlabel="Month",
    ylabel="Cost (EUR)",
    legend=:outertopright,
    size=(1000, 600),
    grid=true,
    xlims=(0.5, simulation_months + 0.5),
    xticks=1:simulation_months,
    margins=5Plots.mm
)

# Extract monthly grand coalition costs
grand_coalition_costs = monthlyGrandCoalitionCosts

# Plot grand coalition costs (total imbalance cost)
plot!(p, 1:simulation_months, grand_coalition_costs, 
      label="Grand Coalition Total Cost", 
      linewidth=4,
      marker=:circle,
      markersize=8,
      color=:black,
      linestyle=:solid)

# Plot individual client Gately allocation costs
for client in clients
    monthly_gately_costs = []
    for month in 1:simulation_months
        if haskey(monthlyAllocationCosts[month], "gately") && haskey(monthlyAllocationCosts[month]["gately"], client)
            push!(monthly_gately_costs, monthlyAllocationCosts[month]["gately"][client])
        else
            push!(monthly_gately_costs, 0.0)
        end
    end
    
    plot!(p, 1:simulation_months, monthly_gately_costs, 
          label="Client $client (Gately)", 
          linewidth=2,
          marker=:circle,
          markersize=4)
end

# Also add the sum of Gately costs for comparison
gately_total_costs = []
for month in 1:simulation_months
    if haskey(monthlyAllocationCosts[month], "gately")
        total_gately_cost = sum(values(monthlyAllocationCosts[month]["gately"]))
        push!(gately_total_costs, total_gately_cost)
    else
        push!(gately_total_costs, 0.0)
    end
end

plot!(p, 1:simulation_months, gately_total_costs, 
      label="Gately Total (Sum)", 
      linewidth=3,
      marker=:square,
      markersize=6,
      color=:red,
      linestyle=:dash)

display(p)

# =========================
# 4. Plot Client Costs: Gately vs Flat Rate vs Difference
# =========================
println("Creating client cost comparison plot...")

# Create subplots for each client plus one for grand coalition
num_clients = length(clients)
p_clients = plot(layout=(num_clients + 1, 1), size=(1000, 300*(num_clients + 1)))

for (i, client) in enumerate(clients)
    # Extract monthly Gately costs for this client
    monthly_gately_costs = []
    for month in 1:simulation_months
        if haskey(monthlyAllocationCosts[month], "gately") && haskey(monthlyAllocationCosts[month]["gately"], client)
            push!(monthly_gately_costs, monthlyAllocationCosts[month]["gately"][client])
        else
            push!(monthly_gately_costs, 0.0)
        end
    end
    
    # Extract monthly flat rate income for this client
    monthly_flat_rate_income = []
    for month in 1:simulation_months
        push!(monthly_flat_rate_income, monthlyClientFlatRateIncome[month][client])
    end
    
    # Convert Gately costs to negative (expenses), keep flat rate positive (income)
    monthly_gately_costs_neg = -monthly_gately_costs
    monthly_flat_rate_income_pos = monthly_flat_rate_income
    
    # Calculate the sum (net position: income - costs)
    monthly_net_position = monthly_flat_rate_income_pos .+ monthly_gately_costs_neg
    
    # Plot for this client
    plot!(p_clients[i], 1:simulation_months, monthly_gately_costs_neg, 
          label="Cost of client (Gately Point)", 
          linewidth=3,
          marker=:circle,
          markersize=6,
          color=:blue,
          title="Client $client: Monthly Financial Position",
          xlabel="Month",
          ylabel="Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          xlims=(0.5, simulation_months + 0.5),
          xticks=1:simulation_months,
          margins=3Plots.mm)
    
    plot!(p_clients[i], 1:simulation_months, monthly_flat_rate_income_pos, 
          label="Flat Rate Payment (10€/MWh)", 
          linewidth=3,
          marker=:square,
          markersize=6,
          color=:green)
    
    plot!(p_clients[i], 1:simulation_months, monthly_net_position, 
          label="Net Position (Income + Cost)", 
          linewidth=3,
          marker=:diamond,
          markersize=6,
          color=:red,
          linestyle=:dash)
    
    # Add horizontal line at zero for reference
    hline!(p_clients[i], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

# Add grand coalition subplot
if num_clients > 0
    # Calculate total costs across all clients for each month
    monthly_total_gately = [sum(haskey(monthlyAllocationCosts[month], "gately") && haskey(monthlyAllocationCosts[month]["gately"], client) ? monthlyAllocationCosts[month]["gately"][client] : 0.0 for client in clients) for month in 1:simulation_months]
    monthly_total_flat_rate = [sum(monthlyClientFlatRateIncome[month][client] for client in clients) for month in 1:simulation_months]
    
    # Calculate values for grand coalition subplot
    monthly_total_gately_neg = -monthly_total_gately
    monthly_total_flat_rate_pos = monthly_total_flat_rate
    monthly_total_net_position = monthly_total_flat_rate_pos .+ monthly_total_gately_neg
    
    # Plot grand coalition data in the last subplot
    subplot_index = num_clients + 1
    plot!(p_clients[subplot_index], 1:simulation_months, monthly_total_gately_neg, 
          label="Total Gately Allocation (Cost)", 
          linewidth=3,
          marker=:circle,
          markersize=6,
          color=:blue,
          title="Grand Coalition: Total Monthly Financial Position",
          xlabel="Month",
          ylabel="Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          xlims=(0.5, simulation_months + 0.5),
          xticks=1:simulation_months,
          margins=3Plots.mm)
    
    plot!(p_clients[subplot_index], 1:simulation_months, monthly_total_flat_rate_pos, 
          label="Total Flat Rate Payments (Income)", 
          linewidth=3,
          marker=:square,
          markersize=6,
          color=:green)
    
    plot!(p_clients[subplot_index], 1:simulation_months, monthly_total_net_position, 
          label="Total Net Position (Income + Cost)", 
          linewidth=3,
          marker=:diamond,
          markersize=6,
          color=:red,
          linestyle=:dash)
    
    # Add horizontal line at zero for reference
    hline!(p_clients[subplot_index], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_clients)

# =========================
# 5. Plot Client Costs: Gately vs CVaR-based Payments
# =========================
println("Creating client cost comparison plot with CVaR-based payments...")

# Create subplots for each client plus one for grand coalition
num_clients_cvar = length(clients)
p_clients_cvar = plot(layout=(num_clients_cvar + 1, 1), size=(1000, 300*(num_clients_cvar + 1)))

for (i, client) in enumerate(clients)
    # Extract monthly Gately costs for this client
    monthly_gately_costs = []
    for month in 1:simulation_months
        if haskey(monthlyAllocationCosts[month], "gately") && haskey(monthlyAllocationCosts[month]["gately"], client)
            push!(monthly_gately_costs, monthlyAllocationCosts[month]["gately"][client])
        else
            push!(monthly_gately_costs, 0.0)
        end
    end
    
    # Extract monthly CVaR-based payments for this client
    monthly_cvar_payments = []
    for month in 1:simulation_months
        push!(monthly_cvar_payments, monthlyClientCVaRPayments[month][client])
    end
    
    # Convert Gately costs to negative (expenses), keep CVaR payments positive (income)
    monthly_gately_costs_neg = -monthly_gately_costs
    monthly_cvar_payments_pos = monthly_cvar_payments
    
    # Calculate the sum (net position: income - costs)
    monthly_net_position_cvar = monthly_cvar_payments_pos .+ monthly_gately_costs_neg
    
    # Plot for this client
    plot!(p_clients_cvar[i], 1:simulation_months, monthly_gately_costs_neg, 
          label="Cost of client (Gately Point)", 
          linewidth=3,
          marker=:circle,
          markersize=6,
          color=:blue,
          title="Client $client: Monthly Financial Position (CVaR-based Payments)",
          xlabel="Month",
          ylabel="Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          xlims=(0.5, simulation_months + 0.5),
          xticks=1:simulation_months,
          margins=3Plots.mm)
    
    plot!(p_clients_cvar[i], 1:simulation_months, monthly_cvar_payments_pos, 
          label="CVaR-based Payment", 
          linewidth=3,
          marker=:square,
          markersize=6,
          color=:orange)
    
    plot!(p_clients_cvar[i], 1:simulation_months, monthly_net_position_cvar, 
          label="Net Position (Income + Cost)", 
          linewidth=3,
          marker=:diamond,
          markersize=6,
          color=:red,
          linestyle=:dash)
    
    # Add horizontal line at zero for reference
    hline!(p_clients_cvar[i], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

# Add grand coalition subplot for CVaR-based payments
if num_clients_cvar > 0
    # Calculate total costs across all clients for each month
    monthly_total_gately_cvar = [sum(haskey(monthlyAllocationCosts[month], "gately") && haskey(monthlyAllocationCosts[month]["gately"], client) ? monthlyAllocationCosts[month]["gately"][client] : 0.0 for client in clients) for month in 1:simulation_months]
    monthly_total_cvar_payments = [sum(monthlyClientCVaRPayments[month][client] for client in clients) for month in 1:simulation_months]
    
    # Calculate values for grand coalition subplot
    monthly_total_gately_neg_cvar = -monthly_total_gately_cvar
    monthly_total_cvar_payments_pos = monthly_total_cvar_payments
    monthly_total_net_position_cvar = monthly_total_cvar_payments_pos .+ monthly_total_gately_neg_cvar
    
    # Plot grand coalition data in the last subplot
    subplot_index_cvar = num_clients_cvar + 1
    plot!(p_clients_cvar[subplot_index_cvar], 1:simulation_months, monthly_total_gately_neg_cvar, 
          label="Total Gately Allocation (Cost)", 
          linewidth=3,
          marker=:circle,
          markersize=6,
          color=:blue,
          title="Grand Coalition: Total Monthly Financial Position (CVaR-based)",
          xlabel="Month",
          ylabel="Amount (EUR)",
          legend=:outerbottom,
          legend_columns=3,
          grid=true,
          xlims=(0.5, simulation_months + 0.5),
          xticks=1:simulation_months,
          margins=3Plots.mm)
    
    plot!(p_clients_cvar[subplot_index_cvar], 1:simulation_months, monthly_total_cvar_payments_pos, 
          label="Total CVaR-based Payments (Income)", 
          linewidth=3,
          marker=:square,
          markersize=6,
          color=:orange)
    
    plot!(p_clients_cvar[subplot_index_cvar], 1:simulation_months, monthly_total_net_position_cvar, 
          label="Total Net Position (Income + Cost)", 
          linewidth=3,
          marker=:diamond,
          markersize=6,
          color=:red,
          linestyle=:dash)
    
    # Add horizontal line at zero for reference
    hline!(p_clients_cvar[subplot_index_cvar], [0], color=:black, linestyle=:dot, alpha=0.5, label="")
end

display(p_clients_cvar)
