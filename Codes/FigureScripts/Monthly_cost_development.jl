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
clients = ["A","G"]

start_hour = DateTime(2023, 11, 01, 00, 0, 0)
simulation_months = 12
month_length = 30 # Days in a month

num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 20 # Number of scenarios for imbalance spread
spread_scens_length = 1 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
alphaCVaR = 0.05 # CVaR confidence level
beta = 0 # Weighting factor between cost and CVaR in total cost calculation
dailyPlot = false # Whether to run the daily calculations

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
    push!(monthlyClientDemand, sum(Matrix(demandData[!, clients]), dims=1) |> vec)

end


# Plot of income with flat MWh fee
flat_rate_fee = 10 # EUR/MWh

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
    grid=true
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

# Display summary statistics
println("\n=== Monthly Cost Comparison Summary ===")
println("Grand Coalition Costs: $(round.(grand_coalition_costs, digits=2))")
println("Gately Total Costs: $(round.(gately_total_costs, digits=2))")
println("Total Grand Coalition Cost: $(round(sum(grand_coalition_costs), digits=2)) EUR")
println("Total Gately Cost: $(round(sum(gately_total_costs), digits=2)) EUR")
println("Average Monthly Grand Coalition Cost: $(round(mean(grand_coalition_costs), digits=2)) EUR")
println("Average Monthly Gately Cost: $(round(mean(gately_total_costs), digits=2)) EUR")

println("\nIndividual Client Gately Costs:")
for client in clients
    monthly_gately_costs = []
    for month in 1:simulation_months
        if haskey(monthlyAllocationCosts[month], "gately") && haskey(monthlyAllocationCosts[month]["gately"], client)
            push!(monthly_gately_costs, monthlyAllocationCosts[month]["gately"][client])
        else
            push!(monthly_gately_costs, 0.0)
        end
    end
    
    total_cost = sum(monthly_gately_costs)
    avg_cost = mean(monthly_gately_costs)
    
    println("Client $client:")
    println("  Monthly costs: $(round.(monthly_gately_costs, digits=2))")
    println("  Total cost: $(round(total_cost, digits=2)) EUR")
    println("  Average monthly cost: $(round(avg_cost, digits=2)) EUR")
end

