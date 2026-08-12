# Imbalance Functions for Coalition Analysis
# Functions for calculating imbalances, bids, and costs for bidding coalitions

using JuMP
using HiGHS
using Combinatorics
using Dates
using Statistics
using DataFrames

function get_demand_forecast(coalition, stochasticData, systemData, TimeHorizon)
    forecast_type = stochasticData["demand_forecast"]
    if forecast_type == "perfect"
        return sum(systemData["price_prod_demand_df"][1:TimeHorizon, client] for client in coalition)
    elseif forecast_type == "scenarios"
        return sum(stochasticData["demand_scenarios"][client] for client in coalition)
    elseif forecast_type == "noise"
        std_dev = stochasticData["demand_noise_std"]
        actual_demand = sum(systemData["price_prod_demand_df"][1:TimeHorizon, client] for client in coalition)
        return actual_demand .* (1 .+ std_dev * randn(TimeHorizon, 1))
    else
        error("Unknown demand forecast type: $forecast_type")
    end
end

function get_pv_forecast(stochasticData, systemData, T)
    forecast_type = stochasticData["pv_forecast"]
    if forecast_type == "perfect"
        return systemData["price_prod_demand_df"][1:T, :SolarMWh]
    elseif forecast_type == "scenarios"
        return systemData["price_prod_demand_df"][1:T, :PVForecast]
    else
        error("Unknown PV forecast type: $forecast_type")
    end
end

function optimize_imbalance(coalition, systemData, stochasticData; extendedOutput=false, onePrice = false)
    clientPVOwnership = getindex.(Ref(systemData["clientPVOwnership"]), coalition)
    TimeHorizon = length(systemData["price_prod_demand_df"][!, "HourUTC_datetime"])
    T = min(TimeHorizon, size(systemData["price_prod_demand_df"])[1])
    demand = get_demand_forecast(coalition, stochasticData, systemData, TimeHorizon)
    pvProduction = get_pv_forecast(stochasticData, systemData, T)
    spreadScenarios, spotScenarios = stochasticData["imbalance_spread"], stochasticData["spot_price"]
    # Dominant direction is 0 or 1 here. 0 corresponds to -1 (need for upregulation) in the original dataset. 1 corresponds to +1 (need for downregulation)
    # Needs to be tied to spreadScenarios, pre-generated to speed up optimization
    dominantDirection = stochasticData["dominantDirection01"]
    # If T longer than spreadScenarios, repeat the scenarios
    if size(spreadScenarios, 2) < T
        spreadScenarios = repeat(spreadScenarios, 1, ceil(Int, T / size(spreadScenarios, 2)))
        dominantDirection = repeat(dominantDirection, 1, ceil(Int, T / size(dominantDirection, 2)))
        spotScenarios = repeat(spotScenarios, 1, ceil(Int, T / size(spotScenarios, 2)))
    end
    prod = pvProduction .* sum(clientPVOwnership)

    SDemand = length(demand[1,:])  # Number of demand scenarios
    probDemand = 1/SDemand
    SSpread = length(spreadScenarios[:,1])  # Number of spread scenarios
    probSpread = 1/SSpread

    # Set up optimization model
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, imbal[1:T, 1:SDemand]) # Imbalance amount
    if !onePrice
        # Two-price scheme, separate variables for positive and negative imbalances
        @variable(model, pos_imbal[1:T, 1:SDemand] >= 0) # Positive imbalance, net consumption lower than bid, have excess to sell
        @variable(model, neg_imbal[1:T, 1:SDemand] >= 0) # Negative imbalance, net consumption higher than bid, need to buy more
    end
    maxDemand = maximum(demand)
    maxProd = maximum(prod)
    @variable(model, -maxProd <= bid[1:T] <= maxDemand) # Bid amount

    if onePrice
        # One-price objective, maximize expected revenue
        @objective(model, Max, probSpread * probDemand * sum(
                                    imbal[t, s]*spreadScenarios[sSpread,t] # Cost of imbalance, positive imbalance means selling at imbalance price
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread))
    else
        # Two-price objective, maximize expected revenue
        @objective(model, Max, probSpread * probDemand * sum(
                                    (1-dominantDirection[sSpread,t])*(pos_imbal[t, s]*spreadScenarios[sSpread,t]) # Cost of positive imbalance
                                    - dominantDirection[sSpread,t]*neg_imbal[t, s]*spreadScenarios[sSpread,t] # Cost of negative imbalance
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread))
    end

    @constraint(model, [t = 1:T, s = 1:SDemand],
                demand[t, s] - prod[t] - bid[t] + imbal[t, s] == 0)

    if !onePrice
        @constraint(model, [t = 1:T, s = 1:SDemand],
                   pos_imbal[t, s] - neg_imbal[t, s] == imbal[t, s])
    end

    optimize!(model)
    if termination_status(model) == MOI.OPTIMAL
        if extendedOutput
            if onePrice
                # One-price extended output calculation
                cost = probSpread * probDemand * (sum(
                                    value(imbal[t, s])*spreadScenarios[sSpread,t] # Cost of imbalance in one-price scheme
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread))
                return value.(bid), cost
            else
                # Two-price extended output calculation
                cost = probSpread * probDemand * (sum(
                                    (1-dominantDirection[sSpread,t])*(value(pos_imbal[t, s])*spreadScenarios[sSpread,t]) # Cost of positive imbalance
                                    - dominantDirection[sSpread,t]*value(neg_imbal[t, s])*spreadScenarios[sSpread,t] # Cost of negative imbalance
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread))
                return value.(bid), cost
            end
        else
            return value.(bid)
        end
    else
        println("No optimal solution found")
    end
end

function newsvendor_bidding(coalitions, systemData, stochasticData; onePrice = false)
    # Process all coalitions at once to avoid redundant data handling
    TimeHorizon = length(systemData["price_prod_demand_df"][!, "HourUTC_datetime"])
    T = min(TimeHorizon, size(systemData["price_prod_demand_df"])[1])
    
    # Get PV forecast once (shared across all coalitions)
    pvProduction = get_pv_forecast(stochasticData, systemData, T)
    
    # Get spread scenarios once (shared across all coalitions)
    spreadScenarios = stochasticData["imbalance_spread"]
    
    # If T longer than spreadScenarios, repeat the scenarios once
    if size(spreadScenarios, 2) < T
        spreadScenarios = repeat(spreadScenarios, 1, ceil(Int, T / size(spreadScenarios, 2)))
    end
    
    # Calculate costUp and costDown once (shared across all coalitions)
    costUp = mean(max.(spreadScenarios, 0.0))
    costDown = mean(abs.(min.(spreadScenarios, 0.0)))
    optimalBiddingQuantile = costUp / (costUp + costDown)
    
    # Initialize results dictionary
    bids = Dict()
    
    # Process each coalition
    for coalition in coalitions
        clientPVOwnership = getindex.(Ref(systemData["clientPVOwnership"]), coalition)
        demand = get_demand_forecast(coalition, stochasticData, systemData, TimeHorizon)
        prod = pvProduction .* sum(clientPVOwnership)
        
        # Apply quantile to the distribution of net consumption for each time period
        # demand is [T x scenarios], prod is [T], so we need to broadcast prod across scenarios
        netConsumptionScenarios = demand .- prod  # Broadcasting prod across the scenario dimension
        bids[coalition] = [quantile(netConsumptionScenarios[t, :], optimalBiddingQuantile) for t in 1:T]
    end
    
    return bids
end


function get_imbalance(bids, pvProd, demand)
    # Ensure all vectors have the same length
    min_length = min(length(bids), length(pvProd), length(demand))
    return bids[1:min_length] + pvProd[1:min_length] - demand[1:min_length]
end

function calculate_bids(coalitions, systemData, stochasticData; fullOpt = false, onePrice = false, useNewsvendor = true)
    # This function calculates the bids for each coalition combination
    # Set useNewsvendor = true to use newsvendor_bidding instead of optimize_imbalance
    individual_clients = filter(c -> length(c) == 1, coalitions)
    bids = Dict()
    # Calculate bids for individual clients first
    if useNewsvendor
        # Use newsvendor bidding which processes all coalitions at once
        bids = newsvendor_bidding(individual_clients, systemData, stochasticData; onePrice = onePrice)
    else
        for client in individual_clients
            #println("Calculating bid for client: ", client)
            bids[client] = optimize_imbalance(client, systemData, stochasticData; onePrice = onePrice)
        end
    end


    if fullOpt
        # Full optimization for all coalitions (computationally expensive)
        for coalition in coalitions
            if length(coalition) > 1
                #println("Calculating bid for coalition: ", coalition)
                bids[coalition] = optimize_imbalance(coalition, systemData, stochasticData; onePrice = onePrice)
            end
        end
    else
        # Calculate bids for coalitions by summing individual bids (will not give the same answer as full optimization)
        for coalition in coalitions
            if length(coalition) > 1
                bids[coalition] = reduce(+, (bids[[client]] for client in coalition))
            end
        end
    end
    GC.gc()  # Force garbage collection to free memory
    return bids
end

function create_time_period_data(systemData, startDay, intervals)
    start_interval = findfirst(x -> x >= startDay, systemData["price_prod_demand_df"][!, "HourUTC_datetime"])
    
    # Check if start date was found in the data
    if start_interval === nothing
        data_range = "$(systemData["price_prod_demand_df"][1, "HourUTC_datetime"]) to $(systemData["price_prod_demand_df"][end, "HourUTC_datetime"])"
        error("Start date $startDay not found in available data range: $data_range")
    end
    
    tempData = deepcopy(systemData)
    
    try
        end_interval = start_interval + intervals - 1
        
        # Check if end_interval exceeds available data
        if end_interval > nrow(systemData["price_prod_demand_df"])
            data_range = "$(systemData["price_prod_demand_df"][1, "HourUTC_datetime"]) to $(systemData["price_prod_demand_df"][end, "HourUTC_datetime"])"
            error("Requested time period ($startDay + $intervals intervals) exceeds available data range: $data_range")
        end
        
        tempData["price_prod_demand_df"] = systemData["price_prod_demand_df"][start_interval:end_interval, :]
    catch e
        if isa(e, BoundsError)
            data_range = "$(systemData["price_prod_demand_df"][1, "HourUTC_datetime"]) to $(systemData["price_prod_demand_df"][end, "HourUTC_datetime"])"
            error("Specified time period exceeds available data range: $data_range")
        else
            rethrow(e)
        end
    end
    
    return tempData
end

function set_period!(systemData::Dict{String, Any}, startDay, days)
    # Set up time period for the given number of days
    # This function is used when systemData is passed, it is a dictionary
    intervals_per_day = 24  # 1-hour intervals per day
    intervals = days * intervals_per_day
    return create_time_period_data(systemData, startDay, intervals)
end

function set_period!(demandData::DataFrame, startDay, days)
    # Set up time period for the given number of days
    # This function is used when demandData is passed, it is a DataFrame
    intervals_per_day = 24  # 1-hour intervals per day
    intervals = days * intervals_per_day
    start_interval = findfirst(x -> x >= startDay, demandData[!, "HourUTC_datetime"])
    
    try
        end_interval = start_interval + intervals - 1
        return demandData[start_interval:end_interval, :]
    catch e
        if isa(e, BoundsError)
            data_range = "$(demandData[1, "HourUTC_datetime"]) to $(demandData[end, "HourUTC_datetime"])"
            error("Specified time period exceeds available data range: $data_range")
        else
            rethrow(e)
        end
    end
end

function calculate_WMAPE(imbalancesDict, systemData, coalition)
    # This function calculates the Weighted Mean Absolute Percentage Error (WMAPE)
    # WMAPE = sum(|actual - forecast|) / sum(|actual|) * 100
    # It compares the imbalances with the demand in systemData

    if length(coalition) == 1
        demand = systemData["price_prod_demand_df"][!, coalition]
        production = systemData["price_prod_demand_df"][!, :SolarMWh] .* systemData["clientPVOwnership"][coalition]
        imbalances = imbalancesDict[[coalition]]
    else
        demand = sum(systemData["price_prod_demand_df"][!, client] for client in coalition)
        production = systemData["price_prod_demand_df"][!, :SolarMWh] .* sum(systemData["clientPVOwnership"][client] for client in coalition)
        imbalances = imbalancesDict[coalition]
    end
    
    
    
    # WMAPE calculation: sum of absolute errors divided by sum of actual values
    total_absolute_error = sum(abs.(imbalances))
    total_actual = sum(abs.(demand-production))
    
    WMAPE = (total_absolute_error / total_actual) * 100  # Convert to percentage
    
    return WMAPE
end

function calculate_imbalances_specific(systemData, coalitions, stochasticData, simDays; dummy = false, onePrice = false, useNewsvendor = false, fullOpt = true)
    # Calculate imbalances for specific coalitions
    T = simDays * 24
    # Get all clients
    all_clients = coalitions[argmax(length.(coalitions))]
    if dummy
        # Use dummy bidding (sum of individual medians) for bids
        bids = dummy_bidding(stochasticData, all_clients, coalitions, systemData)
    else
        # Use two-price optimization for bids
        bids = calculate_bids(coalitions, systemData, stochasticData; fullOpt = fullOpt, onePrice = onePrice, useNewsvendor = useNewsvendor)
    end
    # Pre-calculate actual demand and PV for each client
    actual_demand_per_client = Dict()
    actual_pv_per_client = Dict()
    for client in all_clients
        actual_demand_per_client[client] = systemData["price_prod_demand_df"][1:T, client]
        actual_pv_per_client[client] = systemData["price_prod_demand_df"][1:T, :SolarMWh] .* systemData["clientPVOwnership"][client]
    end
    
    # Calculate imbalances for each coalition by summing individual components
    imbalancesDict = Dict()
    for coalition in coalitions
        # Sum bids for this coalition
        coalition_bids = bids[coalition]
        
        # Sum actual demand for this coalition
        coalition_demand = sum(actual_demand_per_client[client] for client in coalition)
        
        # Sum actual PV for this coalition
        coalition_pv = sum(actual_pv_per_client[client] for client in coalition)
        
        # Calculate actual imbalances
        actual_imbalances = get_imbalance(coalition_bids, coalition_pv, coalition_demand)
        
        imbalancesDict[coalition] = actual_imbalances
    end
    return imbalancesDict, bids
end

function calculate_total_costs_specific(systemData, coalitions, stochasticData, simDays; dummy = false, onePrice = false, useNewsvendor = true, fullOpt = false)
    # Calculate the expected imbalance cost for each coalition

    # Get imbalances and bids for all coalitions (unified calculation)
    T = simDays * 24
    imbalance_spread = systemData["price_prod_demand_df"][1:T, "ImbalanceSpreadEUR"]

    # Get imbalances for all coalitions
    imbalancesDict, bids = calculate_imbalances_specific(systemData, coalitions, stochasticData, simDays; dummy = dummy, onePrice = onePrice, useNewsvendor = useNewsvendor, fullOpt = fullOpt)

    # Pre-allocate results
    costs_dict = Dict{Any, Float64}()
    sizehint!(costs_dict, length(coalitions))

    for coalition in coalitions
        # Get imbalances for this coalition
        actual_imbalances = imbalancesDict[coalition]

        # Calculate imbalance costs (positive imbalance means selling at imbalance price, if spread is positive then this is good)
        imbalance_costs = actual_imbalances .* imbalance_spread
        if onePrice
            costs_dict[coalition] = sum(imbalance_costs)
        else
            # Calculate regular costs (two-price system - only positive costs)
            imbalance_costs = min.(0, imbalance_costs)
            costs_dict[coalition] = sum(imbalance_costs)
        end
    end
    return costs_dict, imbalancesDict
end

function sparse_coalitions(clients)
    # Generates coalitions needed for Gately and simple mechanisms
    n = length(clients)
    relevant_coalitions = []
    
    # Add individual coalitions (size 1)
    for client in clients
        push!(relevant_coalitions, [client])
    end
    
    
    # Add grand coalition (size N)
    push!(relevant_coalitions, clients)
    
    # Add all coalitions of size N-1 (exclude one client at a time)
    for i in 1:n
        coalition_wo_i = [clients[j] for j in 1:n if j != i]
        push!(relevant_coalitions, coalition_wo_i)
    end
    return relevant_coalitions
end

function dummy_bidding(stochasticData, clients, coalitions, systemData)
    demandScenarios = stochasticData["demand_scenarios"]
    solarMWh = systemData["price_prod_demand_df"][!, :PVForecast]
    
    # Calculate individual client bids (demand - PV production) in one step
    individual_bids = Dict(client => vec(mean(demandScenarios[client], dims=2)) - solarMWh .* systemData["clientPVOwnership"][client] 
                          for client in clients)
    
    # Calculate bids for all subcoalitions
    return Dict(subcoal => sum(individual_bids[client] for client in subcoal) 
                for subcoal in coalitions if !isempty(subcoal))
end

function scale_equal!(systemData)
    """
    Scale all client demand columns in systemData["price_prod_demand_df"] to have the same 
    maximum demand as the client with the highest maximum demand.
    
    Args:
        systemData: Dictionary containing the system data with "price_prod_demand_df" DataFrame
                   and "clientPVOwnership" dictionary
    
    Modifies systemData["price_prod_demand_df"] in place.
    """
    df = systemData["price_prod_demand_df"]
    
    # Get all client names from clientPVOwnership keys
    clients = collect(keys(systemData["clientPVOwnership"]))
    
    # Calculate maximum demand for each client
    max_demands = Dict{String, Float64}()
    for client in clients
        if hasproperty(df, Symbol(client))
            max_demands[client] = maximum(df[!, Symbol(client)])
        end
    end
    
    # Find the overall maximum demand across all clients
    if isempty(max_demands)
        @warn "No client columns found in price_prod_demand_df"
        return
    end
    
    global_max_demand = maximum(values(max_demands))
    
    # Scale each client's demand to match the global maximum
    for client in clients
        if hasproperty(df, Symbol(client)) && max_demands[client] > 0
            scaling_factor = global_max_demand / max_demands[client]
            df[!, Symbol(client)] .*= scaling_factor
        end
    end
    
    println("Scaled all client demands to maximum demand of $global_max_demand")
    return nothing
end