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
CVaRFull = true # Full plot with all coalitions
fullPlotSimple = false # All days, only simple allocation
fullPlot = false # All days, all allocations
dailyPlot = false # Daily plot, all allocations

systemData, clients, demandData = load_data()
firstHour = minimum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
lastHour = maximum(systemData["price_prod_demand_df"][!, :HourUTC_datetime])
# Filter out smallest clients for full plot all coalitions, down from 22 to 19
clients = filter(x -> !(x in ["X", "W", "N"]), clients)
# Filter down to 12 for nucleolus
#clients = filter(x -> !(x in ["F", "V", "J","E", "T", "O", "Y"]), clients)

# Last hour 2025-07-20T03:45:00
start_hour = DateTime(2025, 4, 04, 00, 0, 0)
#start_hour = DateTime(2025, 3, 04, 12, 0, 0)
#start_hour = start_hour + Dates.Day(3) # Start at 00:00 of the next day
#sim_days = 50
sim_days = Int(floor((lastHour - start_hour) / Dates.Day(1)))-1 # Calculate number of days from start_hour to lastHour
println("Simulation period: ", start_hour, " to ", start_hour + Dates.Day(sim_days - 1))
println("Number of simulation days: ", sim_days)
num_scenarios_demand = 5
num_scenarios_price = 30 # Number of scenarios for imbalance spread
spread_scens_length = 96 # Sets the length of the imbalance spread scenarios, will repeat after this if necessary
chunkSize = 3 # Days processed at a time when calculating imbalance costs, adjust based on memory

stochasticData = Dict(
    # Accepted forecast types: "perfect", "scenarios", "noise"
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    # Set standard deviations in percent for noise
    # Adjusting so demand MAE is 7-10% and PV MAE is 22.5-25%
    # Note: PV forecast gives MAE of 22.5-25% using scenarios
    "demand_noise_std" => 0.28,
    "pv_noise_std" => 0.32
)

if stochasticData["demand_forecast"] == "scenarios"
    stochasticData["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demandData, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

if stochasticData["pv_forecast"] == "noise"
    stochasticData["pv_forecast_noise"] = generate_noise_forecast_PV(systemData, start_hour, sim_days)
end
stochasticData["imbalance_spread"] = generate_scenarios_imbalance_spread(systemData, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochasticData["dominantDirection01"] = generate_dominant_direction(stochasticData["imbalance_spread"])

# Cut systemData and demandData to the simulation period
systemData = set_period!(systemData, start_hour, sim_days)
demandData = set_period!(demandData, start_hour, sim_days)

allocations = [
    "shapley",
    "VCG",
    "VCG_budget_balanced",
    "gately",
    #"gately_daily",
    "gately_interval",
    "full_cost", # Uniform price for cost
    "reduced_cost",
    #"nucleolus",
    "flat_rate",
    "cost_based" # Uniform price for CVaR
]

# =========================
# 2. Imbalance Calculation and allocation
# =========================
if CVaRFull
    alphaCVaR = 0.05
    # Remove allocation methods that are not suitable for CVaR yet
    allocations = filter(x -> !(x in ["full_cost", "reduced_cost", "flat_rate", "gately_interval"]), allocations)
    CVaRDict, imbalancesDict = @time calculate_CVaR(
        systemData, clients, stochasticData; printing=true, chunkSize=chunkSize, alpha=alphaCVaR
    )

    allocation_costs = calculate_allocations(
        allocations, clients, CVaRDict, imbalancesDict, systemData, demandData; printing = true, alpha=alphaCVaR
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


    #serialize("Results/CVaR_scenPV_scenDemand.jls", cvar_plot_data)
end
if fullPlotSimple
    # Remove complex allocations for simple plot
    allocations = filter(x -> !(x in ["shapley", "nucleolus"]), allocations)
    println("Calculating imbalance costs for full plot (simple)...")
    coalitions = sparse_coalitions(clients)
    coalitionCosts, imbalancesDict = @time calculate_costs_specific(
        systemData, coalitions, stochasticData, sim_days
    )
    allocation_costs = calculate_allocations(
        allocations, clients, coalitionCosts, imbalancesDict, systemData, demandData; printing = true
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
    serialize("Results/simple_plot_scenPV_scenDemand.jls", simple_plot_data)

end
if fullPlot
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
        allocations, clients, coalitions, coalitionCosts, imbalances, imbalancesDict, systemData, demandData; printing = true
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
    serialize("Results/nuc_scenarios.jls", plot_data)
end
# Remove flat_rate allocation until it is fixed
#allocations = filter(x -> x != "flat_rate", allocations)
# Remove nucleolus allocation as it is too slow 
if dailyPlot
    allocations = filter(x -> x != "nucleolus", allocations)


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

    # Save variance plot data to the "Results" subfolder
    serialize("Results/variance_plot_data_scenDemand_scenPV.jls", variance_plot_data)

end
GC.gc() # Run garbage collection to free memory after processing


