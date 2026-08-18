# Imbalance Functions for Coalition Analysis
# Functions for calculating imbalances, bids, and costs for bidding coalitions

using JuMP
using HiGHS
using Combinatorics
using Dates
using Statistics
using DataFrames

function get_demand_forecast(coalition, stochastic_data, system_data, time_horizon)
    forecast_type = stochastic_data["demand_forecast"]
    if forecast_type == "perfect"
        return sum(system_data["price_prod_demand_df"][1:time_horizon, client] for client in coalition)
    elseif forecast_type == "scenarios"
        return sum(stochastic_data["demand_scenarios"][client] for client in coalition)
    elseif forecast_type == "noise"
        std_dev = stochastic_data["demand_noise_std"]
        actual_demand = sum(system_data["price_prod_demand_df"][1:time_horizon, client] for client in coalition)
        return actual_demand .* (1 .+ std_dev * randn(time_horizon, 1))
    else
        error("Unknown demand forecast type: $forecast_type")
    end
end

function get_pv_forecast(stochastic_data, system_data, T)
    forecast_type = stochastic_data["pv_forecast"]
    if forecast_type == "perfect"
        return system_data["price_prod_demand_df"][1:T, :SolarMWh]
    elseif forecast_type == "scenarios"
        return system_data["price_prod_demand_df"][1:T, :PVForecast]
    else
        error("Unknown PV forecast type: $forecast_type")
    end
end

function optimize_imbalance(coalition, system_data, stochastic_data; extended_output=false, one_price = false)
    client_pv_ownership = getindex.(Ref(system_data["client_pv_ownership"]), coalition)
    time_horizon = length(system_data["price_prod_demand_df"][!, "HourUTC_datetime"])
    T = min(time_horizon, size(system_data["price_prod_demand_df"])[1])
    demand = get_demand_forecast(coalition, stochastic_data, system_data, time_horizon)
    pv_production = get_pv_forecast(stochastic_data, system_data, T)
    spread_scenarios, spot_scenarios = stochastic_data["imbalance_spread"], stochastic_data["spot_price"]
    # Dominant direction is 0 or 1 here. 0 corresponds to -1 (need for upregulation) in the original dataset. 1 corresponds to +1 (need for downregulation)
    # Scenario-indexed (not the historical DominantDirection column), tied to spread_scenarios, pre-generated to speed up optimization
    dominant_direction_scenarios = stochastic_data["dominant_direction_scenarios"]
    # If T longer than spread_scenarios, repeat the scenarios
    if size(spread_scenarios, 2) < T
        spread_scenarios = repeat(spread_scenarios, 1, ceil(Int, T / size(spread_scenarios, 2)))
        dominant_direction_scenarios = repeat(dominant_direction_scenarios, 1, ceil(Int, T / size(dominant_direction_scenarios, 2)))
        spot_scenarios = repeat(spot_scenarios, 1, ceil(Int, T / size(spot_scenarios, 2)))
    end
    prod = pv_production .* sum(client_pv_ownership)

    num_demand_scenarios = length(demand[1,:])  # Number of demand scenarios
    prob_demand = 1/num_demand_scenarios
    num_spread_scenarios = length(spread_scenarios[:,1])  # Number of spread scenarios
    prob_spread = 1/num_spread_scenarios

    # Set up optimization model
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, imbal[1:T, 1:num_demand_scenarios]) # Imbalance amount
    if !one_price
        # Two-price scheme, separate variables for positive and negative imbalances
        @variable(model, pos_imbal[1:T, 1:num_demand_scenarios] >= 0) # Positive imbalance, net consumption lower than bid, have excess to sell
        @variable(model, neg_imbal[1:T, 1:num_demand_scenarios] >= 0) # Negative imbalance, net consumption higher than bid, need to buy more
    end
    max_demand = maximum(demand)
    max_prod = maximum(prod)
    @variable(model, -max_prod <= bid[1:T] <= max_demand) # Bid amount

    if one_price
        # One-price objective, maximize expected revenue
        @objective(model, Max, prob_spread * prob_demand * sum(
                                    imbal[t, s]*spread_scenarios[spread_idx,t] # Cost of imbalance, positive imbalance means selling at imbalance price
                                    for t in 1:T for s in 1:num_demand_scenarios for spread_idx in 1:num_spread_scenarios))
    else
        # Two-price objective, maximize expected revenue
        @objective(model, Max, prob_spread * prob_demand * sum(
                                    (1-dominant_direction_scenarios[spread_idx,t])*(pos_imbal[t, s]*spread_scenarios[spread_idx,t]) # Cost of positive imbalance
                                    - dominant_direction_scenarios[spread_idx,t]*neg_imbal[t, s]*spread_scenarios[spread_idx,t] # Cost of negative imbalance
                                    for t in 1:T for s in 1:num_demand_scenarios for spread_idx in 1:num_spread_scenarios))
    end

    @constraint(model, [t = 1:T, s = 1:num_demand_scenarios],
                demand[t, s] - prod[t] - bid[t] + imbal[t, s] == 0)

    if !one_price
        @constraint(model, [t = 1:T, s = 1:num_demand_scenarios],
                   pos_imbal[t, s] - neg_imbal[t, s] == imbal[t, s])
    end

    optimize!(model)
    if termination_status(model) == MOI.OPTIMAL
        if extended_output
            if one_price
                # One-price extended output calculation
                cost = prob_spread * prob_demand * (sum(
                                    value(imbal[t, s])*spread_scenarios[spread_idx,t] # Cost of imbalance in one-price scheme
                                    for t in 1:T for s in 1:num_demand_scenarios for spread_idx in 1:num_spread_scenarios))
                return value.(bid), cost
            else
                # Two-price extended output calculation
                cost = prob_spread * prob_demand * (sum(
                                    (1-dominant_direction_scenarios[spread_idx,t])*(value(pos_imbal[t, s])*spread_scenarios[spread_idx,t]) # Cost of positive imbalance
                                    - dominant_direction_scenarios[spread_idx,t]*value(neg_imbal[t, s])*spread_scenarios[spread_idx,t] # Cost of negative imbalance
                                    for t in 1:T for s in 1:num_demand_scenarios for spread_idx in 1:num_spread_scenarios))
                return value.(bid), cost
            end
        else
            return value.(bid)
        end
    else
        println("No optimal solution found")
    end
end

function newsvendor_bidding(coalitions, system_data, stochastic_data; one_price = false)
    # Process all coalitions at once to avoid redundant data handling
    time_horizon = length(system_data["price_prod_demand_df"][!, "HourUTC_datetime"])
    T = min(time_horizon, size(system_data["price_prod_demand_df"])[1])

    # Get PV forecast once (shared across all coalitions)
    pv_production = get_pv_forecast(stochastic_data, system_data, T)

    # Get spread scenarios once (shared across all coalitions)
    spread_scenarios = stochastic_data["imbalance_spread"]

    # If T longer than spread_scenarios, repeat the scenarios once
    if size(spread_scenarios, 2) < T
        spread_scenarios = repeat(spread_scenarios, 1, ceil(Int, T / size(spread_scenarios, 2)))
    end

    # Calculate cost_up and cost_down once (shared across all coalitions)
    cost_up = mean(max.(spread_scenarios, 0.0))
    cost_down = mean(abs.(min.(spread_scenarios, 0.0)))
    optimal_bidding_quantile = cost_up / (cost_up + cost_down)

    # Initialize results dictionary
    bids = Dict()

    # Process each coalition
    for coalition in coalitions
        client_pv_ownership = getindex.(Ref(system_data["client_pv_ownership"]), coalition)
        demand = get_demand_forecast(coalition, stochastic_data, system_data, time_horizon)
        prod = pv_production .* sum(client_pv_ownership)

        # Apply quantile to the distribution of net consumption for each time period
        # demand is [T x scenarios], prod is [T], so we need to broadcast prod across scenarios
        net_consumption_scenarios = demand .- prod  # Broadcasting prod across the scenario dimension
        bids[coalition] = [quantile(net_consumption_scenarios[t, :], optimal_bidding_quantile) for t in 1:T]
    end

    return bids
end


function get_imbalance(bids, pv_prod, demand)
    # Ensure all vectors have the same length
    min_length = min(length(bids), length(pv_prod), length(demand))
    return bids[1:min_length] + pv_prod[1:min_length] - demand[1:min_length]
end

function calculate_bids(coalitions, system_data, stochastic_data; full_opt = false, one_price = false, use_newsvendor = true)
    # This function calculates the bids for each coalition combination
    # Set use_newsvendor = true to use newsvendor_bidding instead of optimize_imbalance
    # Deliberately the union over all coalitions rather than filtering `coalitions` for
    # singletons -- callers may pass a partial batch of coalitions (see Imbalance_main.jl's
    # coalition batching) that doesn't happen to include every client's own singleton, and every
    # client referenced by any multi-client coalition in the batch still needs its own bid
    # computed below so `reduce(+, (bids[[client]] for client in coalition))` can find it. Also
    # deliberately NOT all of client_pv_ownership's keys: that dict holds every raw client from
    # the data file, including ones the caller may have filtered out (e.g. Imbalance_main.jl's
    # CLIENT_EXCLUSION_PRESETS) before ever building `coalitions`, and those excluded clients
    # have no entry in stochastic_data["demand_scenarios"].
    individual_clients = [[c] for c in unique(reduce(vcat, coalitions))]
    bids = Dict()
    # Calculate bids for individual clients first
    if use_newsvendor
        # Use newsvendor bidding which processes all coalitions at once
        bids = newsvendor_bidding(individual_clients, system_data, stochastic_data; one_price = one_price)
    else
        for client in individual_clients
            bids[client] = optimize_imbalance(client, system_data, stochastic_data; one_price = one_price)
        end
    end


    if full_opt
        # Full optimization for all coalitions (computationally expensive)
        for coalition in coalitions
            if length(coalition) > 1
                bids[coalition] = optimize_imbalance(coalition, system_data, stochastic_data; one_price = one_price)
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

function find_period_start_index(datetimes, start_day)
    # Find the first index in a sorted HourUTC_datetime column with value >= start_day
    start_interval = findfirst(x -> x >= start_day, datetimes)
    if start_interval === nothing
        data_range = "$(datetimes[1]) to $(datetimes[end])"
        error("Start date $start_day not found in available data range: $data_range")
    end
    return start_interval
end

function create_time_period_data(system_data, start_day, intervals)
    start_interval = find_period_start_index(system_data["price_prod_demand_df"][!, "HourUTC_datetime"], start_day)

    temp_data = deepcopy(system_data)

    try
        end_interval = start_interval + intervals - 1

        # Check if end_interval exceeds available data
        if end_interval > nrow(system_data["price_prod_demand_df"])
            data_range = "$(system_data["price_prod_demand_df"][1, "HourUTC_datetime"]) to $(system_data["price_prod_demand_df"][end, "HourUTC_datetime"])"
            error("Requested time period ($start_day + $intervals intervals) exceeds available data range: $data_range")
        end

        temp_data["price_prod_demand_df"] = system_data["price_prod_demand_df"][start_interval:end_interval, :]
    catch e
        if isa(e, BoundsError)
            data_range = "$(system_data["price_prod_demand_df"][1, "HourUTC_datetime"]) to $(system_data["price_prod_demand_df"][end, "HourUTC_datetime"])"
            error("Specified time period exceeds available data range: $data_range")
        else
            rethrow(e)
        end
    end

    return temp_data
end

function set_period(system_data::Dict{String, Any}, start_day, days)
    # Set up time period for the given number of days
    # This method is used when system_data is passed, it is a dictionary
    # Returns a new Dict; does not mutate system_data (see create_time_period_data)
    intervals_per_day = 24  # 1-hour intervals per day
    intervals = days * intervals_per_day
    return create_time_period_data(system_data, start_day, intervals)
end

function set_period(demand_data::DataFrame, start_day, days)
    # Set up time period for the given number of days
    # This method is used when demand_data is passed, it is a DataFrame
    # Returns a new DataFrame slice; does not mutate demand_data
    intervals_per_day = 24  # 1-hour intervals per day
    intervals = days * intervals_per_day
    start_interval = find_period_start_index(demand_data[!, "HourUTC_datetime"], start_day)

    try
        end_interval = start_interval + intervals - 1
        return demand_data[start_interval:end_interval, :]
    catch e
        if isa(e, BoundsError)
            data_range = "$(demand_data[1, "HourUTC_datetime"]) to $(demand_data[end, "HourUTC_datetime"])"
            error("Specified time period exceeds available data range: $data_range")
        else
            rethrow(e)
        end
    end
end

function calculate_wmape(coalition_imbalances, system_data, coalition)
    # This function calculates the Weighted Mean Absolute Percentage Error (WMAPE)
    # WMAPE = sum(|actual - forecast|) / sum(|actual|) * 100
    # It compares the imbalances with the demand in system_data

    if length(coalition) == 1
        demand = system_data["price_prod_demand_df"][!, coalition]
        production = system_data["price_prod_demand_df"][!, :SolarMWh] .* system_data["client_pv_ownership"][coalition]
        imbalances = coalition_imbalances[[coalition]]
    else
        demand = sum(system_data["price_prod_demand_df"][!, client] for client in coalition)
        production = system_data["price_prod_demand_df"][!, :SolarMWh] .* sum(system_data["client_pv_ownership"][client] for client in coalition)
        imbalances = coalition_imbalances[coalition]
    end

    # WMAPE calculation: sum of absolute errors divided by sum of actual values
    total_absolute_error = sum(abs.(imbalances))
    total_actual = sum(abs.(demand-production))

    wmape = (total_absolute_error / total_actual) * 100  # Convert to percentage

    return wmape
end

function calculate_imbalances_specific(system_data, coalitions, stochastic_data, sim_days; dummy = false, one_price = false, use_newsvendor = true, full_opt = false)
    # Calculate imbalances for specific coalitions
    T = sim_days * 24
    # Get all clients referenced anywhere in `coalitions`. Deliberately the union over all
    # coalitions rather than the largest single one present -- callers may pass a partial batch
    # of coalitions (see Imbalance_main.jl's coalition batching) that doesn't happen to include
    # the grand coalition, and every client referenced by any coalition in the batch still needs
    # its demand/PV precomputed below. Also deliberately NOT all of client_pv_ownership's keys:
    # that dict holds every raw client from the data file, including ones the caller may have
    # filtered out (e.g. Imbalance_main.jl's CLIENT_EXCLUSION_PRESETS) before ever building
    # `coalitions`, and those excluded clients have no entry in stochastic_data["demand_scenarios"].
    all_clients = unique(reduce(vcat, coalitions))
    if dummy
        # Use dummy bidding (sum of individual medians) for bids
        bids = dummy_bidding(stochastic_data, all_clients, coalitions, system_data)
    else
        # Use two-price optimization for bids
        bids = calculate_bids(coalitions, system_data, stochastic_data; full_opt = full_opt, one_price = one_price, use_newsvendor = use_newsvendor)
    end
    # Pre-calculate actual demand and PV for each client
    actual_demand_per_client = Dict()
    actual_pv_per_client = Dict()
    for client in all_clients
        actual_demand_per_client[client] = system_data["price_prod_demand_df"][1:T, client]
        actual_pv_per_client[client] = system_data["price_prod_demand_df"][1:T, :SolarMWh] .* system_data["client_pv_ownership"][client]
    end

    # Calculate imbalances for each coalition by summing individual components
    coalition_imbalances = Dict()
    for coalition in coalitions
        # Sum bids for this coalition
        coalition_bids = bids[coalition]

        # Sum actual demand for this coalition
        coalition_demand = sum(actual_demand_per_client[client] for client in coalition)

        # Sum actual PV for this coalition
        coalition_pv = sum(actual_pv_per_client[client] for client in coalition)

        # Calculate actual imbalances
        actual_imbalances = get_imbalance(coalition_bids, coalition_pv, coalition_demand)

        coalition_imbalances[coalition] = actual_imbalances
    end
    return coalition_imbalances, bids
end

function calculate_total_costs_specific(system_data, coalitions, stochastic_data, sim_days; dummy = false, one_price = false, use_newsvendor = true, full_opt = false)
    # Calculate the simulated imbalance cost for each coalition over the given period

    # Get imbalances and bids for all coalitions (unified calculation)
    T = sim_days * 24
    imbalance_spread = system_data["price_prod_demand_df"][1:T, "ImbalanceSpreadEUR"]

    # Get imbalances for all coalitions (bids are computed as an intermediate step but not needed here)
    coalition_imbalances, _ = calculate_imbalances_specific(system_data, coalitions, stochastic_data, sim_days; dummy = dummy, one_price = one_price, use_newsvendor = use_newsvendor, full_opt = full_opt)

    # Pre-allocate results
    costs_dict = Dict{Any, Float64}()
    sizehint!(costs_dict, length(coalitions))

    for coalition in coalitions
        # Get imbalances for this coalition
        actual_imbalances = coalition_imbalances[coalition]

        # Calculate imbalance costs (positive imbalance means selling at imbalance price, if spread is positive then this is good)
        imbalance_costs = actual_imbalances .* imbalance_spread
        if one_price
            costs_dict[coalition] = sum(imbalance_costs)
        else
            # Two-price system: keep only cost entries (imbalance_costs <= 0), zero out income (positive) entries
            imbalance_costs = min.(0, imbalance_costs)
            costs_dict[coalition] = sum(imbalance_costs)
        end
    end
    return costs_dict, coalition_imbalances
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

function dummy_bidding(stochastic_data, clients, coalitions, system_data)
    demand_scenarios = stochastic_data["demand_scenarios"]
    solar_mwh = system_data["price_prod_demand_df"][!, :PVForecast]

    # Calculate individual client bids (demand - PV production) in one step
    individual_bids = Dict(client => vec(mean(demand_scenarios[client], dims=2)) - solar_mwh .* system_data["client_pv_ownership"][client]
                          for client in clients)

    # Calculate bids for all subcoalitions
    return Dict(subcoal => sum(individual_bids[client] for client in subcoal)
                for subcoal in coalitions if !isempty(subcoal))
end

"""
    scale_equal!(system_data)

Scale all client demand columns in `system_data["price_prod_demand_df"]` to have the same
maximum demand as the client with the highest maximum demand.

Modifies `system_data["price_prod_demand_df"]` in place.
"""
function scale_equal!(system_data)
    df = system_data["price_prod_demand_df"]

    # Get all client names from client_pv_ownership keys
    clients = collect(keys(system_data["client_pv_ownership"]))

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
