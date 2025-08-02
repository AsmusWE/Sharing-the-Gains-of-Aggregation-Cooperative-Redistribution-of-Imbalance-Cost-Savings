# Imbalance Functions for Coalition Analysis
# Functions for calculating imbalances, bids, and CVaR for bidding coalitions

using JuMP
using HiGHS
using Combinatorics
using Dates
using Statistics

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

function optimize_imbalance(coalition, systemData, stochasticData)
    clientPVOwnership = getindex.(Ref(systemData["clientPVOwnership"]), coalition)
    TimeHorizon = length(systemData["price_prod_demand_df"][!, "HourUTC_datetime"])
    T = min(TimeHorizon, size(systemData["price_prod_demand_df"])[1])
    
    demand = get_demand_forecast(coalition, stochasticData, systemData, TimeHorizon)
    pvProduction = get_pv_forecast(stochasticData, systemData, T)
    spreadScenarios = stochasticData["imbalance_spread"]
    # Dominant direction is 0 or 1 here. 0 corresponds to -1 (need for upregulation) in the original dataset. 1 corresponds to +1 (need for downregulation)
    # Needs to be tied to spreadScenarios, pre-generated to speed up optimization
    dominantDirection = stochasticData["dominantDirection01"]
    # If T longer than spreadScenarios, repeat the scenarios
    if size(spreadScenarios, 2) < T
        spreadScenarios = repeat(spreadScenarios, 1, ceil(Int, T / size(spreadScenarios, 2)))
        dominantDirection = repeat(dominantDirection, 1, ceil(Int, T / size(dominantDirection, 2)))
    end
    prod = pvProduction .* sum(clientPVOwnership)
    
    SDemand = length(demand[1,:])  # Number of demand scenarios
    probDemand = 1/SDemand
    SSpread = length(spreadScenarios[:,1])  # Number of spread scenarios
    probSpread = 1/SSpread

    # Set up optimization model
    model = Model(HiGHS.Optimizer)
    #model = Model(Gurobi.Optimizer)
    #set_optimizer_attribute(model, "OutputFlag", 0)
    set_silent(model)

    @variable(model, imbal[1:T, 1:SDemand]) # Imbalance amount
    @variable(model, pos_imbal[1:T, 1:SDemand] >= 0) # Positive imbalance
    @variable(model, neg_imbal[1:T, 1:SDemand] >= 0) # Negative imbalance
    @variable(model, bid[1:T]) # Bid amount

    # Two-price objective
    @objective(model, Min, probSpread * probDemand * sum(((dominantDirection[sSpread,t])*pos_imbal[t, s]*(spreadScenarios[sSpread,t]) + (1-dominantDirection[sSpread,t])*neg_imbal[t, s]*(-spreadScenarios[sSpread,t])) for t in 1:T for s in 1:SDemand for sSpread in 1:SSpread)) # Objective function
    #@objective(model, Min, probDemand * sum((pos_imbal[t, s] + neg_imbal[t, s]) for t in 1:T for s in 1:SDemand))

    @constraint(model, [t = 1:T, s = 1:SDemand],
                imbal[t, s] == demand[t, s] - prod[t] - bid[t])
    @constraint(model, [t = 1:T, s = 1:SDemand], pos_imbal[t, s] - neg_imbal[t, s] == imbal[t, s])
    solution = optimize!(model)
    if termination_status(model) == MOI.OPTIMAL
        #println("Optimal solution found")
        #println("Objective value: ", objective_value(model))
        #println("pos_imbal: ", value.(pos_imbal))
        #println("neg_imbal: ", value.(neg_imbal))
        #print(a)
        return value.(bid)
    else
        println("No optimal solution found")
    end
end

function get_imbalance(bids, pvProd, demand)
    # Ensure all vectors have the same length
    min_length = min(length(bids), length(pvProd), length(demand))
    return bids[1:min_length] + pvProd[1:min_length] - demand[1:min_length]
end

function calculate_imbalance(systemData, clients, stochasticData)
    coalitions = collect(combinations(clients))
    n_coalitions = length(coalitions)
    bids_dict = calculate_bids(coalitions, systemData, stochasticData)
    
    # Pre-allocate arrays for better performance
    demand_sum_vec = Vector{Vector{Float64}}(undef, n_coalitions)
    scaled_pvProd_vec = Vector{Vector{Float64}}(undef, n_coalitions)
    for (i, coalition) in enumerate(coalitions)
        demand_sum_vec[i] = sum(systemData["price_prod_demand_df"][!, c] for c in coalition)
        scaled_pvProd_vec[i] = systemData["price_prod_demand_df"][!, "SolarMWh"] .* sum(systemData["clientPVOwnership"][c] for c in coalition)
    end
    
    return coalitions, demand_sum_vec, scaled_pvProd_vec, bids_dict
end

function calculate_bids(coalitions, systemData, stochasticData)
    # This function calculates the bids for each coalition combination
    bids = Dict()
    
    # Calculate bids for individual clients first
    individual_clients = filter(c -> length(c) == 1, coalitions)
    for client in individual_clients
        bids[client] = optimize_imbalance(client, systemData, stochasticData)
    end
    
    # Calculate bids for coalitions by summing individual bids
    for coalition in coalitions
        if length(coalition) > 1
            bids[coalition] = sum(bids[[client]] for client in coalition)
        end
    end
    
    return bids
end

function chunk_imbalance(systemData, clients, stochasticData; printing=false, chunkSize = 14)
    # chunkSize is in days
    # Calculate the starting interval index
    coalitions = collect(combinations(clients))
    n_coalitions = length(coalitions)
    # Constants
    INTERVALS_PER_DAY = 96  # 15-min intervals per day
    intervals_per_chunk = chunkSize * INTERVALS_PER_DAY
    total_intervals = size(systemData["price_prod_demand_df"], 1)
    num_chunks = ceil(Int, total_intervals / intervals_per_chunk)
    
    # Initialize result matrix
    period_interval_imbalance = zeros(n_coalitions, total_intervals)
    
    for chunk_idx in 1:num_chunks
        printing && println("Processing chunk $chunk_idx of $num_chunks")
        
        # Calculate chunk boundaries
        start_idx = (chunk_idx - 1) * intervals_per_chunk + 1
        chunk_length = min(intervals_per_chunk, total_intervals - start_idx + 1)
        
        # Prepare chunk data
        chunk_data, chunk_stochasticData = prepare_chunk_data(systemData, stochasticData, start_idx, chunk_length, INTERVALS_PER_DAY)

        # Calculate imbalances for this chunk
        coalitions, demand_vec, pv_vec, bids_dict = calculate_imbalance(chunk_data, clients, chunk_stochasticData)

        # Store results
        end_idx = start_idx + chunk_length - 1
        for (i, coalition) in enumerate(coalitions)
            imbalance = get_imbalance(bids_dict[coalition], pv_vec[i], demand_vec[i])
            period_interval_imbalance[i, start_idx:end_idx] = imbalance
        end
        
        GC.gc()  # Force garbage collection
    end
    
    return coalitions, period_interval_imbalance
end

function prepare_chunk_data(systemData, stochasticData, start_idx, chunk_length, intervals_per_day)
    chunk_start_day = systemData["price_prod_demand_df"][start_idx, "HourUTC_datetime"]
    chunk_days = div(chunk_length, intervals_per_day)
    chunk_data = set_period!(systemData, chunk_start_day, chunk_days)
    chunk_stochasticData = deepcopy(stochasticData)

    # Adjust scenario data if present
    if haskey(stochasticData, "demand_scenarios")
        chunk_stochasticData["demand_scenarios"] = Dict()
        for (client, scenarios) in stochasticData["demand_scenarios"]
            end_idx = start_idx + chunk_length - 1
            chunk_stochasticData["demand_scenarios"][client] = scenarios[start_idx:end_idx, :]
        end
    end
    
    # Adjust PV forecast noise if present
    if haskey(stochasticData, "pv_forecast_noise")
        end_idx = start_idx + chunk_length - 1
        chunk_stochasticData["pv_forecast_noise"] = stochasticData["pv_forecast_noise"][start_idx:end_idx]
    end

    return chunk_data, chunk_stochasticData
end


function calculate_CVaR(systemData, clients, startDay, days; alpha=0.05, printing=false, chunkSize=14)
    # Validate inputs
    alpha > 0 && alpha < 1 || error("Alpha must be between 0 and 1, got $alpha")
    
    # Set up time period
    intervals_per_day = 96
    intervals = days * intervals_per_day
    tempData = create_time_period_data(systemData, startDay, intervals)
    
    # Calculate imbalances for all coalitions
    coalitions, period_interval_imbalance = chunk_imbalance(tempData, clients; printing=printing, chunksize=chunkSize)
    
    # Calculate CVaR for each coalition
    imbalance_spread = tempData["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    cvar_dict, imbalance_dict = calculate_cvar_values(coalitions, period_interval_imbalance, imbalance_spread, alpha)
    
    return cvar_dict, imbalance_dict
end

function imbalance_costs(systemData, clients, startDay, days, stochasticData; printing=false, chunkSize=14)
    # Validate inputs
    days > 0 || error("Days must be greater than 0, got $days")
    
    # Set up time period
    intervals_per_day = 96
    intervals = days * intervals_per_day
    tempData = create_time_period_data(systemData, startDay, intervals)
    
    # Calculate imbalances for all coalitions
    coalitions, period_interval_imbalance = chunk_imbalance(tempData, clients, stochasticData; printing=printing, chunkSize=chunkSize)

    # Calculate imbalance costs for each coalition
    imbalance_spread = tempData["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominantDirection = tempData["price_prod_demand_df"][!, "DominatingDirection"]
    
    # Memory-efficient calculation: process each coalition individually to avoid large matrices
    coalition_costs = Dict{Any, Float64}()
    imbalanceDict = Dict{Any, SubArray{Float64}}()
    
    abs_spread = abs.(imbalance_spread)  # Pre-compute absolute values
    n_coalitions = length(coalitions)
    progress_interval = max(1, div(n_coalitions, 20))  # Print progress 20 times total
    
    for (i, coalition) in enumerate(coalitions)
        # Calculate costs for this coalition only, avoiding intermediate matrices
        total_cost = 0.0
        imbalance_row = view(period_interval_imbalance, i, :)
        
        # Vectorized processing of all time intervals
        imbalance_with_dir = imbalance_row .* dominantDirection
        positive_imbalance = max.(imbalance_with_dir, 0)
        total_cost = sum(positive_imbalance .* abs_spread)
        
        coalition_costs[coalition] = total_cost
        imbalanceDict[coalition] = imbalance_row
        
        # Print progress at regular intervals
        if (i % progress_interval == 0 || i == n_coalitions) && printing
            percentage = round(100 * i / n_coalitions, digits=1)
            println("Processing coalition $i of $n_coalitions ($percentage%)")
        end
    end

    return coalition_costs, period_interval_imbalance, imbalanceDict
end

function create_time_period_data(systemData, startDay, intervals)
    start_interval = findfirst(x -> x >= startDay, systemData["price_prod_demand_df"][!, "HourUTC_datetime"])
    tempData = deepcopy(systemData)
    
    try
        end_interval = start_interval + intervals - 1
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
    intervals_per_day = 96  # 15-min intervals per day
    intervals = days * intervals_per_day
    return create_time_period_data(systemData, startDay, intervals)
end

function set_period!(demandData::DataFrame, startDay, days)
    # Set up time period for the given number of days
    # This function is used when demandData is passed, it is a DataFrame
    intervals_per_day = 96  # 15-min intervals per day
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

function calculate_cvar_values(coalitions, period_interval_imbalance, imbalance_spread, alpha)
    n_coalitions = length(coalitions)
    intervals = size(period_interval_imbalance, 2)
    var_index = ceil(Int, intervals * alpha)
    
    # Pre-allocate results
    cvar_dict = Dict{Any, Float64}()
    imbalance_dict = Dict{Any, Vector{Float64}}()
    sizehint!(cvar_dict, n_coalitions)
    sizehint!(imbalance_dict, n_coalitions)
    
    for (i, coalition) in enumerate(coalitions)
        # Calculate costs and CVaR
        imbalance_costs = period_interval_imbalance[i, :] .* imbalance_spread
        partialsort!(imbalance_costs, 1:var_index, rev=true)
        cvar_value = mean(imbalance_costs[1:var_index])
        
        # Store results
        cvar_dict[coalition] = cvar_value
        imbalance_dict[coalition] = view(period_interval_imbalance, i, :)
    end
    
    return cvar_dict, imbalance_dict
end

function calculate_MAE(imbalancesDict, systemData, coalition)
    # This function calculates the mean absolute error (MAE) of the model and divides by average demand
    # It compares the imbalances with the demand in systemData

    demand = sum(systemData["price_prod_demand_df"][!, client] for client in coalition)

    MAE = sum(abs.(imbalancesDict[coalition]))/length(imbalancesDict[coalition])
    percentMAE = MAE / (sum(demand)/length(imbalancesDict[coalition]))

    return MAE
end

function calculate_MAE_old(systemData, stochasticData, clients, start_interval, days; forecastType = "demand")
    # Calculate the Mean Absolute Error (MAE) of the forecast
    # NOTE: CURRENTLY ONLY WORKING FOR DEMAND FORECASTS
    totalDemand = 0
    totalDemandInterval = zeros(size(systemData["price_prod_demand_df"], 1))
    demandForecastType = stochasticData["demand_forecast"]
    for client in clients
        # Get the demand for the client
        totalDemand += sum(systemData["price_prod_demand_df"][!, client])
        totalDemandInterval .+= systemData["price_prod_demand_df"][!, client]
    end
    absDemandError = 0


    if demandForecastType == "scenarios"
        # Set the forecast as the median of the scenarios
        demandForecast = median(get_demand_forecast(clients, stochasticData, systemData, size(systemData["price_prod_demand_df"], 1)), dims=2)
        absDemandError = sum(abs.(demandForecast .- totalDemandInterval))
    else
        # if the forecast is noise, the forecast is generated in the optimization
        # apply noise to the actual demand to approximate the forecast
        demandForecast = zeros(size(systemData["price_prod_demand_df"], 1))
        for client in clients
            demandForecast .+= get_demand_forecast([client], stochasticData, systemData, size(systemData["price_prod_demand_df"], 1))
        end
        absDemandError = sum(abs.(demandForecast .- totalDemandInterval))
    end
    
    println("Total demand: ", totalDemand)
    println("Total demand interval: ", sum(totalDemandInterval))
    println("Absolute demand error: ", absDemandError)
    MAE_Demand = absDemandError / totalDemand

    # Calculate the Mean Absolute Error (MAE) of the PV forecast
    if forecastType == "pv"
        # PV production is scaled according to client PV ownership
        clientPVOwnership = sum(tempData["clientPVOwnership"][c] for c in clients)
        totalPV = sum(tempData["price_prod_demand_df"][!, "SolarMWh"])
        totalPV = totalPV .* clientPVOwnership  # Scale by total PV ownership
        totalPVInterval = sum(tempData["price_prod_demand_df"][!, "SolarMWh"], dims=2)
        totalPVInterval = totalPVInterval .* clientPVOwnership  # Scale by total PV ownership
        # PV forecast is always deterministic
        absPVError = sum(abs.(pvForecast .- totalPVInterval))
        MAE_PV = absPVError / totalPV
        return MAE_PV
    else
        return MAE_Demand
    end
end


function calculate_costs_specific(systemData, coalitions, stochasticData, simDays)
    # Calculate imbalance costs for specific coalitions
    T = simDays * 96 
    imbalance_spread = systemData["price_prod_demand_df"][1:T, "ImbalanceSpreadEUR"]
    dominantDirection = systemData["price_prod_demand_df"][1:T, "DominatingDirection"]
    # Get all clients
    all_clients = coalitions[argmax(length.(coalitions))]
    
    # Calculate bids for each individual client 
    individual_bids = Dict()
    println("Calculating bids for individual clients...")
    for client in all_clients
        individual_bids[client] = optimize_imbalance([client], systemData, stochasticData)
    end
    
    # Pre-calculate actual demand and PV for each client
    actual_demand_per_client = Dict()
    actual_pv_per_client = Dict()
    println("Calculating actual demand and PV for each client...")
    for client in all_clients
        actual_demand_per_client[client] = systemData["price_prod_demand_df"][1:T, client]
        actual_pv_per_client[client] = systemData["price_prod_demand_df"][1:T, :SolarMWh] .* systemData["clientPVOwnership"][client]
    end
    
    # Calculate costs for each coalition by summing individual components
    costs_dict = Dict()
    imbalancesDict = Dict()
    abs_spread = abs.(imbalance_spread)  # Pre-compute absolute values
    println("Calculating costs for each coalition...")
    for coalition in coalitions
        # Sum bids for this coalition
        coalition_bids = sum(individual_bids[client] for client in coalition)
        
        # Sum actual demand for this coalition
        coalition_demand = sum(actual_demand_per_client[client] for client in coalition)
        
        # Sum actual PV for this coalition
        coalition_pv = sum(actual_pv_per_client[client] for client in coalition)
        
        # Calculate actual imbalances
        actual_imbalances = get_imbalance(coalition_bids, coalition_pv, coalition_demand)
        
        # Calculate imbalance costs using the two-price system
        total_cost = 0.0
        for j in eachindex(dominantDirection)
            imbalance_with_dir = actual_imbalances[j] * dominantDirection[j]
            if imbalance_with_dir > 0
                total_cost += imbalance_with_dir * abs_spread[j]
            end
        end
        
        costs_dict[coalition] = total_cost
        imbalancesDict[coalition] = actual_imbalances
    end

    return costs_dict, imbalancesDict
end

function costs_VCG(systemData, clients, startDay, days, stochasticData; printing=false)
    # VCG mechanism requires coalitions of size N-1 and N
    # N-1: all coalitions without one client (needed for VCG calculation)
    # N: the grand coalition (all clients together)
    
    n = length(clients)
    relevant_coalitions = []
    
    # Add grand coalition (size N)
    push!(relevant_coalitions, clients)
    
    # Add all coalitions of size N-1 (exclude one client at a time)
    for i in 1:n
        coalition_wo_i = [clients[j] for j in 1:n if j != i]
        push!(relevant_coalitions, coalition_wo_i)
    end
    
    if printing
        println("costs_VCG: Calculating costs for $(length(relevant_coalitions)) coalitions")
        println("Coalition sizes: $(sort(unique([length(c) for c in relevant_coalitions])))")
    end
    
    # Set up time period
    tempData = set_period!(systemData, startDay, days)
    T = size(tempData["price_prod_demand_df"], 1)
    imbalance_spread = tempData["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominantDirection = tempData["price_prod_demand_df"][!, "DominatingDirection"]
    
    # Calculate costs for all relevant coalitions at once
    costs_dict = calculate_costs_specific(tempData, relevant_coalitions, stochasticData, T, imbalance_spread, dominantDirection)
    GC.gc()  # Force garbage collection to free memory
    return costs_dict
end

function costs_Gately(systemData, clients, simDays, stochasticData; printing=false)
    # Gately mechanism requires coalitions of size 1, N-1, and N
    # Size 1: individual clients (needed for Gately calculation)
    # Size N-1: all coalitions without one client
    # Size N: the grand coalition
    
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
    
    if printing
        println("costs_Gately: Calculating costs for $(length(relevant_coalitions)) coalitions")
        println("Coalition sizes: $(sort(unique([length(c) for c in relevant_coalitions])))")
    end
    
    # Calculate costs for all relevant coalitions at once
    costs_dict, imbalanceDict = calculate_costs_specific(systemData, relevant_coalitions, stochasticData, simDays)
    GC.gc()  # Force garbage collection to free memory
    return costs_dict
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


