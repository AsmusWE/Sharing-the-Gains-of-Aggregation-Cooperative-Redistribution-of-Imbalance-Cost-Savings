# Imbalance_main.jl
# Main script for running coalition imbalance and allocation analysis
# Author: Asmus Winther Eriksen

# --- Project Modules ---
include("Data_import.jl")
include("Scenario_creation.jl")
include("imbalance_functions.jl")
include("Game_theoretic_functions.jl")
include("Plotting_functions.jl")

# --- External Packages ---
using Plots, Dates, Random, Combinatorics, StatsPlots, Serialization
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
# Choose which calculations to run
CVaRFull = false # CVaR calculation with all coalitions
CVaRFullFileName = "temp.jls" # File name for full CVaR results
CVaRSimple = true # CVaR calculation with simple coalitions
CVaRSimpleFileName = "temp.jls" 
costSimple = false # Cost only simple allocation
costSimpleFileName = "temp.jls"
costFull = false # Cost all allocations
costFullFileName = "temp.jls"
dailyPlot = false # Daily plot for cost, all allocations
dailyPlotFileName = "temp.jls"

# Choose which allocations to calculate
allocations = [
    #"shapley",
    "VCG",
    "VCG_budget_balanced",
    "gately",
    "gately_interval",
    "full_cost", # Uniform price for cost
    "reduced_cost",
    #"nucleolus",
    "flat_rate",
    #"cost_based" # Uniform price for CVaR
]


systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
#clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)

start_hour = DateTime(2025, 4, 04, 00, 0, 0)
sim_days = Int(floor((lastHour - start_hour) / Dates.Day(1)))-1 # Calculate number of days from start_hour to lastHour
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days - 1))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5 # Number of scenarios for demand
num_scenarios_price = 1 # Number of scenarios for imbalance spread
spread_scens_length = 96 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
chunkSize = 3 # Days processed at a time when calculating imbalance costs in the full coalition calculations, adjust based on memory
alphaCVaR = 0.05 # CVaR confidence level

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

stochasticData["imbalance_spread"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)


# =========================
# 2. Imbalance Calculation and allocation
# =========================
if CVaRFull
    # Remove allocation methods that are not suitable for CVaR
    allocations = filter(x -> !(x in ["full_cost", "reduced_cost", "gately_interval"]), allocations)
    CVaRDict, imbalancesDict = @time calculate_CVaR(
        systemData, clients, stochasticData; printing=true, chunkSize=chunkSize, alpha=alphaCVaR
    )

    allocation_costs = calculate_allocations(
        allocations, clients, CVaRDict, imbalancesDict, systemData; printing = true, alpha=alphaCVaR
    )

    println("Checking stability for CVaR allocations...")
    max_instability = Dict{String, Float64}()
    for alloc in allocations
        println("Checking stability for allocation: ", alloc)
        max_instability[alloc] = check_stability(allocation_costs[alloc], CVaRDict, clients)
    end
    println("Max instabilities: ", max_instability)

    println("Total CVaR: ", CVaRDict[clients])
    println("VCG CVaR: ", sum(values(allocation_costs["VCG"])))

    # Save CVaR data for plotting 
    cvar_plot_data = SimplePlotData(
        allocations,
        systemData,
        allocation_costs,
        CVaRDict,
        imbalancesDict,
        clients,
        start_hour,
        sim_days
    )
    serialize("Results/" * CVaRFullFileName, cvar_plot_data)
end
if CVaRSimple 
    # Remove allocation methods that are not suitable for CVaR yet
    allocations = filter(x -> !(x in ["full_cost", "reduced_cost", "gately_interval"]), allocations)
    # Remove allocation methods that do not work with the simple calculations 
    allocations = filter(x -> !(x in ["shapley", "nucleolus"]), allocations)
    coalitions = sparse_coalitions(clients)
    println("Calculating CVaR for simple plot...")
    CVaRDict, imbalancesDict = @time calculate_CVaR_specific(
        systemData, coalitions, stochasticData, sim_days;  alpha=alphaCVaR
    )

    allocation_costs = calculate_allocations(
        allocations, clients, CVaRDict, imbalancesDict, systemData; printing = true, alpha=alphaCVaR
    )

    println("Total CVaR: ", CVaRDict[clients])
    println("VCG CVaR: ", sum(values(allocation_costs["VCG"])))

    # Save CVaR data for plotting 
    cvar_plot_data = SimplePlotData(
        allocations,
        systemData,
        allocation_costs,
        CVaRDict,
        imbalancesDict,
        clients,
        start_hour,
        sim_days
    )


    serialize("Results/" * CVaRSimpleFileName, cvar_plot_data)
end
if costSimple
    # Remove complex allocations for simple plot
    allocations = filter(x -> !(x in ["shapley", "nucleolus"]), allocations)
    # Remove CVaR allocations for simple plot
    allocations = filter(x -> !(x in ["cost_based"]), allocations)
    println("Calculating imbalance costs for full plot (simple)...")
    coalitions = sparse_coalitions(clients)
    coalitionCosts, imbalancesDict = @time calculate_costs_specific(
        systemData, coalitions, stochasticData, sim_days
    )
    allocation_costs = calculate_allocations(
        allocations, clients, coalitionCosts, imbalancesDict, systemData; printing = true
    )
    println("Total costs calculated for all coalitions.")
    #println("Allocation costs: ", allocation_costs)

    MAE = calculate_MAE(imbalancesDict, systemData, clients)
    println("MAE: ", MAE)
    println("Total coalition costs: ", coalitionCosts[clients])
    println("Total singleton costs: ", sum(coalitionCosts[[client]] for client in clients))

    # Create an instance of SimplePlotData
    simple_plot_data = SimplePlotData(
        allocations,
        systemData,
        allocation_costs,
        coalitionCosts,
        imbalancesDict,
        clients,
        start_hour,
        sim_days
    )

    # Save simple_plot_data to the "Results" subfolder
    serialize("Results/" * costSimpleFileName, simple_plot_data)

end
if costFull
    coalitions = collect(combinations(clients))
    # Calculating costs
    println("Calculating imbalance costs...")
    coalitionCosts, imbalances, imbalancesDict = @time imbalance_costs(systemData, clients, start_hour, sim_days, stochasticData; printing=true, chunkSize=chunkSize)

    # Checking MAE
    MAE = calculate_MAE(imbalancesDict, systemData, clients)
    println("MAE: ", MAE)

    # Calculating allocations
    println("Calculating allocations...")
    #daily_cost_MWh_imbalance, allocation_costs, imbalances, hourly_imbalances = @time allocation_variance(allocations, clients, coalitions, systemData, start_hour, sim_days)

    allocation_costs = calculate_allocations(
        allocations, clients, coalitionCosts, imbalancesDict, systemData; printing = true
        )

    # Checking stability
    max_instability = Dict{String, Float64}()
    for alloc in allocations
        println("Checking stability for allocation: ", alloc)
        max_instability[alloc] = check_stability(allocation_costs[alloc], coalitionCosts, clients)
    end
    println("Max instabilities: ", max_instability)

    # Compare the sum of individual client CVaR with the grand coalition CVaR
    grand_coalition = clients
    grand_coalition_Cost = coalitionCosts[grand_coalition]

    individual_Cost_sum = sum(coalitionCosts[[client]] for client in clients)

    resProd >= resCap*capVar # If capVar = 1, resprod must be equal to resCap
    addProd <= addCap*capVar # If capVar = 0, addprod must be 0
    # addProd can only be larger than 0 if resProd=resCap


    println("Grand coalition Cost: ", grand_coalition_Cost)
    println("Sum of individual client Cost: ", individual_Cost_sum)
    #println("Difference: ", grand_coalition_imbalance - individual_imbalance_sum)
    if "VCG" in allocations
        VCG_cost = sum(values(allocation_costs["VCG"]))
        println("VCG cost: ", VCG_cost)
        println("VCG subsidies: ", grand_coalition_Cost - VCG_cost)
    end

    # Define a struct to hold all relevant plotting data
    struct PlotData
        allocations::Vector{String}
        systemData::Dict{String, Any}
        allocation_costs::Dict{String, Any}
        imbalances::Dict{Any, Any}
        clients::Vector{String}
        start_hour::DateTime
        sim_days::Int
        daily_cost_MWh_imbalance::Any
    end

    # Create an instance of PlotData
    plot_data = PlotData(
        allocations,
        systemData,
        allocation_costs,
        coalitionCosts,
        clients,
        start_hour,
        sim_days,
        0 # Placeholder for daily_cost_MWh_imbalance, as it is not calculated in this script
    )
    # Save plot_data to the "Results" subfolder
    serialize("Results/" * costFullFileName, plot_data)
end

if dailyPlot
    allocations = filter(x -> x != "nucleolus", allocations)
    allocations = filter(x -> x != "cost_based", allocations)
    allocations = filter(x -> x != "shapley", allocations)

    println("Calculating allocations for daily plot...")

    GC.gc() # Run garbage collection to free memory before processing
    dailyCostAllocations, totalCostAllocations, totalImbalanceCosts, intervalImbalances, singletonCostsDaily = @time allocation_variance(allocations, clients, systemData, stochasticData, demandData, start_hour, sim_days)

    # Define a struct to hold variance plot data
    struct VariancePlotData
        allocations::Vector{String}
        totalCostAllocations::Dict{String, Any}
        dailyCostAllocations::Any
        totalImbalanceCosts::Dict{Any, Any}
        intervalImbalances::Any
        singletonCostsDaily::Any
        clients::Vector{String}
        sim_days::Int
    end

    # Create an instance of VariancePlotData
    variance_plot_data = VariancePlotData(
        allocations,
        totalCostAllocations,
        dailyCostAllocations,
        totalImbalanceCosts,
        intervalImbalances,
        singletonCostsDaily,
        clients,
        sim_days
    )
    println("Total singleton costs: ", sum(sum(singletonCostsDaily[client] for client in clients)))
    println("Total costs for all allocations: ", totalImbalanceCosts[clients])
    # Save variance plot data to the "Results" subfolder
    serialize("Results/" * dailyPlotFileName, variance_plot_data)

end
GC.gc() # Run garbage collection to free memory after processing


