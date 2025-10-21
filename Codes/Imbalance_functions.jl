# Imbalance Functions for Coalition Analysis
# Functions for calculating imbalances, bids, and CVaR for bidding coalitions

using JuMP
using HiGHS
using Combinatorics
using Dates
using Statistics
using Gurobi
using DataFrames

# Define Gurobi environment, needed to supress outputs
const GUROBI_ENV = Gurobi.Env()

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
    elseif forecast_type == "noise"
        return stochasticData["pv_forecast_noise"][1:T]
    else
        error("Unknown PV forecast type: $forecast_type")
    end
end

function optimize_imbalance(coalition, systemData, stochasticData; alpha=0.95, beta = 0.5, extendedOutput=false, onePrice = false)
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
    #model = Model(HiGHS.Optimizer)
    model = Model(()->Gurobi.Optimizer(GUROBI_ENV))
    #set_optimizer_attribute(model, "OutputFlag", 0)
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
    @variable(model, xeta) # Value at Risk (VaR) with bounds
    @variable(model, eta[1:SSpread, 1:SDemand] >= 0) # Auxiliary variables for CVaR
    #@variable(model, PVCurtailment[1:T, 1:SSpread, 1:SDemand] >= 0) #  We assume that we can curtail production.
    # Set upper bounds for PV curtailment
    #for t in 1:T, sSpread in 1:SSpread, s in 1:SDemand
    #    set_upper_bound(PVCurtailment[t, sSpread, s], prod[t])
    #end
    
    if onePrice
        # One-price objective, maximize revenue
        @objective(model, Max, (1-beta)*probSpread * probDemand * sum( 
                                    #(bid[t] + neg_imbal[t, sSpread, s] - pos_imbal[t, sSpread, s]) * spotScenarios[sSpread, t] # DA bid payment and spot price part of imbalance (this cost is covered by the client)
                                    + imbal[t, s]*spreadScenarios[sSpread,t] # Cost of imbalance, positive imbalance means selling at imbalance price 
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread)
                                + beta*(xeta - (1/(1-alpha)*sum(probSpread * probDemand * eta[sSpread, s] for s in 1:SDemand for sSpread in 1:SSpread))))
    else
        # Two-price objective, maximize revenue
        @objective(model, Max, (1-beta)*probSpread * probDemand * sum( 
                                    #(bid[t] + neg_imbal[t, sSpread, s] - pos_imbal[t, sSpread, s]) * spotScenarios[sSpread, t] # DA bid payment and spot price part of imbalance (this cost is covered by the client)
                                    + (1-dominantDirection[sSpread,t])*(pos_imbal[t, s]*spreadScenarios[sSpread,t]) # Cost of positive imbalance
                                    - dominantDirection[sSpread,t]*neg_imbal[t, s]*spreadScenarios[sSpread,t] # Cost of negative imbalance
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread)
                                + beta*(xeta - (1/(1-alpha)*sum(probSpread * probDemand * eta[sSpread, s] for s in 1:SDemand for sSpread in 1:SSpread))))
    end

    #@objective(model, Min, (1-beta)*probSpread * probDemand * sum(
    #                        dominantDirection[sSpread,t]*pos_imbal[t, s]*spreadScenarios[sSpread,t] + (1-dominantDirection[sSpread,t])*neg_imbal[t, s]*(-spreadScenarios[sSpread,t]) for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread)
    #                        + beta*(xeta
    #                        + # Changed this from minus to plus, is this correct?
    #                        (1/(1-alpha)*sum(probSpread * probDemand * eta[sSpread, s] for s in 1:SDemand for sSpread in 1:SSpread))))

    #@objective(model, Min, probDemand * sum((pos_imbal[t, s] + neg_imbal[t, s]) for t in 1:T for s in 1:SDemand))

    #@constraint(model, [t = 1:T, s = 1:SDemand, sSpread = 1:SSpread],
    #            demand[t, s] - prod[t] - bid[t] + PVCurtailment[t, sSpread, s] - imbal[t, sSpread, s] == 0)
    @constraint(model, [t = 1:T, s = 1:SDemand],
                demand[t, s] - prod[t] - bid[t] + imbal[t, s] == 0)

    if !onePrice
        @constraint(model, [t = 1:T, s = 1:SDemand], 
                   pos_imbal[t, s] - neg_imbal[t, s] == imbal[t, s])
    end

    #@constraint(model, [sSpread = 1:SSpread, s = 1:SDemand],
    #            eta[sSpread, s] >= sum(dominantDirection[sSpread,t]*pos_imbal[t, s]*spreadScenarios[sSpread,t] + (1-dominantDirection[sSpread,t])*neg_imbal[t, s]*(-spreadScenarios[sSpread,t]) for t in 1:T) - xeta)
    if onePrice
        @constraint(model, [sSpread = 1:SSpread, s = 1:SDemand],
                            -sum(
                                #(bid[t] + neg_imbal[t, sSpread, s] - pos_imbal[t, sSpread, s]) * spotScenarios[sSpread, t] # DA bid payment and spot price part of imbalance (this cost is covered by the client)
                                + imbal[t, s]*spreadScenarios[sSpread,t] # Cost of imbalance
                                for t in 1:T) 
                            + xeta
                            - eta[sSpread, s] <= 0)
    else
        @constraint(model, [sSpread = 1:SSpread, s = 1:SDemand],
                                -sum(
                                    #(bid[t] + neg_imbal[t, sSpread, s] - pos_imbal[t, sSpread, s]) * spotScenarios[sSpread, t] # DA bid payment and spot price part of imbalance (this cost is covered by the client)
                                    + (1-dominantDirection[sSpread,t])*(pos_imbal[t, s]*spreadScenarios[sSpread,t]) # Cost of positive imbalance
                                    - dominantDirection[sSpread,t]*neg_imbal[t, s]*spreadScenarios[sSpread,t] # Cost of negative imbalance
                                    for t in 1:T) 
                                + xeta
                                - eta[sSpread, s] <= 0)
    end
    
    solution = optimize!(model)
    if termination_status(model) == MOI.OPTIMAL
        #print(objective_value(model), "\n")
        if extendedOutput
            if onePrice
                # One-price extended output calculation
                cost = probSpread * probDemand * (sum( 
                                    value(imbal[t, s])*spreadScenarios[sSpread,t] # Cost of imbalance in one-price scheme
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread))
                cvar = value(xeta) - (1/(1-alpha)) * probSpread * probDemand * sum(value(eta[sSpread, s]) for s in 1:SDemand for sSpread in 1:SSpread)
                return value.(bid), cost, cvar
            else
                # Two-price extended output calculation
                cost = probSpread * probDemand * (sum( 
                                    #(value(bid[t]) + value(neg_imbal[t, sSpread, s]) - value(pos_imbal[t, sSpread, s])) * spotScenarios[sSpread, t] # DA bid payment and spot price part of imbalance (this cost is covered by the client)
                                    + (1-dominantDirection[sSpread,t])*(value(pos_imbal[t, s])*spreadScenarios[sSpread,t]) # Cost of positive imbalance
                                    - dominantDirection[sSpread,t]*value(neg_imbal[t, s])*spreadScenarios[sSpread,t] # Cost of negative imbalance
                                    for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread))
                cvar = value(xeta) - (1/(1-alpha)) * probSpread * probDemand * sum(value(eta[sSpread, s]) for s in 1:SDemand for sSpread in 1:SSpread)
                return value.(bid), cost, cvar
            end
        else
            return value.(bid)
        end
    else
        println("No optimal solution found")
        #println("Bidding mean net consumption for coalition $(coalition) instead")
        #consumption = [sum(demand[t,s] - prod[t] for s in 1:SDemand) / SDemand for t in 1:T]
        #return consumption
    end
end

function newsvendor_bidding(coalition, systemData, stochasticData; onePrice = false)
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

    # Calculate costUp: average price of positive imbalance (set negative values to 0)
    costUp = mean(max.(spreadScenarios, 0.0))
    
    # Calculate costDown: average price of negative imbalance (set positive values to 0, take absolute value of negatives)
    costDown = mean(abs.(min.(spreadScenarios, 0.0)))
    
    optimalBiddingQuantile = costUp / (costUp + costDown)

    # Apply quantile to the distribution of net consumption for each time period
    # demand is [T x scenarios], prod is [T], so we need to broadcast prod across scenarios
    netConsumptionScenarios = demand .- prod  # Broadcasting prod across the scenario dimension
    bids = [quantile(netConsumptionScenarios[t, :], optimalBiddingQuantile) for t in 1:T]
    return bids
end


function get_imbalance(bids, pvProd, demand)
    # Ensure all vectors have the same length
    min_length = min(length(bids), length(pvProd), length(demand))
    return bids[1:min_length] + pvProd[1:min_length] - demand[1:min_length]
end

function calculate_bids(coalitions, systemData, stochasticData; fullOpt = true, alpha=0.05, beta = 0.05, onePrice = false, useNewsvendor = false)
    # This function calculates the bids for each coalition combination
    # Set useNewsvendor = true to use newsvendor_bidding instead of optimize_imbalance
    bids = Dict()
    
    # Calculate bids for individual clients first
    individual_clients = filter(c -> length(c) == 1, coalitions)
    for client in individual_clients
        #println("Calculating bid for client: ", client)
        if useNewsvendor
            bids[client] = newsvendor_bidding(client, systemData, stochasticData; onePrice = onePrice)
        else
            bids[client] = optimize_imbalance(client, systemData, stochasticData; alpha=alpha, beta=beta, onePrice = onePrice)
        end
    end

    if fullOpt
        # Full optimization for all coalitions (computationally expensive)
        for coalition in coalitions
            if length(coalition) > 1
                #println("Calculating bid for coalition: ", coalition)
                if useNewsvendor
                    bids[coalition] = newsvendor_bidding(coalition, systemData, stochasticData; onePrice = onePrice)
                else
                    bids[coalition] = optimize_imbalance(coalition, systemData, stochasticData; alpha=alpha, beta=beta, onePrice = onePrice)
                end
            end
        end
    else
        # Calculate bids for coalitions by summing individual bids (will not give the same answer as full optimization when using CVaR)
        for coalition in coalitions
            if length(coalition) > 1
                bids[coalition] = sum(bids[[client]] for client in coalition)
            end
        end
    end

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

    demand = sum(systemData["price_prod_demand_df"][!, client] for client in coalition)
    imbalances = imbalancesDict[coalition]
    
    # WMAPE calculation: sum of absolute errors divided by sum of actual values
    total_absolute_error = sum(abs.(imbalances))
    total_actual = sum(abs.(demand))
    
    WMAPE = (total_absolute_error / total_actual) * 100  # Convert to percentage
    
    return WMAPE
end

function calculate_imbalances_specific(systemData, coalitions, stochasticData, simDays; alpha=0.05, beta = 0.5, dummy = false, onePrice = false, useNewsvendor = false)
    # Calculate imbalances for specific coalitions
    T = simDays * 24 
    # Get all clients
    all_clients = coalitions[argmax(length.(coalitions))]
    if dummy
        # Use dummy bidding (sum of individual medians) for bids
        bids = dummy_bidding(stochasticData, all_clients, coalitions, systemData)
    else
        # Use two-price optimization for bids
        bids = calculate_bids(coalitions, systemData, stochasticData; fullOpt = true, alpha = alpha, beta = beta, onePrice = onePrice, useNewsvendor = useNewsvendor)
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

function calculate_total_costs_specific(systemData, coalitions, stochasticData, simDays; alpha=0.05, cost_weight=1.0, cvar_weight=1.0, beta = 0.5, dummy = false, onePrice = false, useNewsvendor = false)
    # Calculate total costs combining both regular imbalance costs and CVaR
    # alpha: confidence level for CVaR calculation
    # cost_weight: weight for regular imbalance costs in the total
    # cvar_weight: weight for CVaR in the total
    
    # Validate inputs
    alpha >= 0 && alpha < 1 || error("Alpha must be positive and below 1, got $alpha")
    cost_weight >= 0 || error("Cost weight must be non-negative, got $cost_weight")
    cvar_weight >= 0 || error("CVaR weight must be non-negative, got $cvar_weight")
    
    if alpha == 0 && cvar_weight > 0
        beta = 0  # If alpha is 0, CVaR will equal the mean
    end

    # Get imbalances and bids for all coalitions (unified calculation)
    T = simDays * 24
    imbalance_spread = systemData["price_prod_demand_df"][1:T, "ImbalanceSpreadEUR"]
    spot_price = systemData["price_prod_demand_df"][1:T, "SpotPriceEUR"]
    
    # Get imbalances for all coalitions
    imbalancesDict, bids = calculate_imbalances_specific(systemData, coalitions, stochasticData, simDays; alpha=alpha, beta=beta, dummy =dummy , onePrice = onePrice, useNewsvendor = useNewsvendor)
    
    # Calculate CVaR for each coalition
    intervals = T
    var_index = ceil(Int, intervals * (1-alpha)) # Index for the Value at Risk (VaR) threshold
    
    # Pre-allocate results
    costs_dict = Dict{Any, Float64}()
    cvar_dict = Dict{Any, Float64}()
    total_costs_dict = Dict{Any, Float64}()
    sizehint!(costs_dict, length(coalitions))
    sizehint!(cvar_dict, length(coalitions))
    sizehint!(total_costs_dict, length(coalitions))

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
            #spot_price_costs = bids[coalition] .* spot_price
            #regular_cost = sum(regular_imbalance_costs + spot_price_costs)
            costs_dict[coalition] = sum(imbalance_costs)
        end
        # Calculate CVaR using all imbalance costs (including negative)
        cvar_costs = copy(imbalance_costs)
        partialsort!(cvar_costs, 1:var_index)
        #cvar_value = mean(cvar_costs[1:var_index])
        tail_cost = sum(cvar_costs[1:var_index])
        #cvar_dict[coalition] = cvar_value
        cvar_dict[coalition] = tail_cost

        # Calculate total costs as weighted sum of regular costs and CVaR
        total_cost = cost_weight * sum(imbalance_costs) + cvar_weight * tail_cost
        total_costs_dict[coalition] = total_cost
    end
    return total_costs_dict, costs_dict, cvar_dict, imbalancesDict
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