using Combinatorics, HiGHS, JuMP#, NLsolve,


function calculate_allocations(
    allocations, clients, coalitionCosts, imbalancesDict,systemData; printing = true, return_time = false
    )
    allocation_times = Dict{String, Float64}()
    allocation_costs = Dict{String, Any}()
    allocation_map = Dict(
        "shapley" => () -> shapley_value(clients, coalitionCosts),
        "MCC" => () -> simple_MCC(clients, coalitionCosts),
        "MCC_budget_balanced" => () -> MCC_BB(clients, coalitionCosts),
        "gately" => () -> deepcopy(gately_point(clients, coalitionCosts)),
        "gately_interval" => () -> deepcopy(gately_point_interval(clients, imbalancesDict, systemData)),
        "full_cost" => () -> deepcopy(full_cost_transfer(clients, imbalancesDict, systemData)),
        "reduced_cost" => () -> deepcopy(reduced_cost(clients, imbalancesDict, systemData)),
        "nucleolus" => () -> begin
            _, nucleolus_values = nucleolus(clients, coalitionCosts)
            deepcopy(nucleolus_values)
        end,
        "equal_share" => () -> deepcopy(equal_allocation(clients, coalitionCosts)),
        "flat_rate" => () -> deepcopy(flat_rate_allocation(clients, coalitionCosts, systemData)),
        "scaled" => () -> deepcopy(scaled_allocation(clients, coalitionCosts))
    )
    allocation_print_map = Dict(
        "shapley" => "Shapley calculation time:",
        "MCC" => "MCC calculation time:",
        "MCC_budget_balanced" => "MCC budget balanced calculation time:",
        "gately" => "Gately calculation time:",
        #"gately_daily" => "Gately calculation time, daily:",
        "gately_interval" => "Gately calculation time, interval:",
        "full_cost" => "Full cost transfer calculation time:",
        "reduced_cost" => "Reduced cost calculation time:",
        "nucleolus" => "Nucleolus calculation time:",
        "equal_share" => "Equal share calculation time:",
        "flat_rate" => "Flat rate calculation time:",
        "scaled" => "Scaled allocation calculation time:"
    )
    for allocation in allocations
        if haskey(allocation_map, allocation)
            if printing && haskey(allocation_print_map, allocation)
                println(allocation_print_map[allocation])
                allocation_costs[allocation] = @time allocation_map[allocation]()
            else
                allocation_costs[allocation] = allocation_map[allocation]()
            end
            if return_time
                allocation_times[allocation] = @elapsed allocation_map[allocation]()
            end
        end
    end
    if return_time
        return allocation_times
    end
    return allocation_costs
    
end

function shapley_value(clients, imbalances)
    # This function calculates the Shapley value for each client in the grand coalition
    n = length(clients)
    shapley_vals = Dict()
    coalitions = collect(combinations(clients))
    for client in clients
        shapley_vals[client] = 0.0
    end

    # Precompute factorials to avoid repeated calculations
    if n > 20
        # Use BigInt for large factorials to avoid overflow
        factorials = [factorial(big(i)) for i in 0:n]
    else
        # Use regular integers for smaller factorials (faster)
        factorials = [factorial(i) for i in 0:n]
    end

    for (idx, i) in enumerate(clients)
        i_coalition = [c for c in coalitions if clients[idx] in c]
        # Looping through all coalitions containing client i
        for c in i_coalition
            S = length(c)
            # Creating the coalition that doesn't contain client i
            c_without_i = filter(x -> x != clients[idx], c)
            # If the coalition without client i is empty, set value of empty coalition as 0
            if isempty(c_without_i)
                imbalance_without_i = 0.0
            else
                imbalance_without_i = imbalances[c_without_i]
            end
            # Calculate the Shapley value contribution for client i in coalition c
            # Use precomputed factorials
            weight = factorials[S] * factorials[n - S + 1] / factorials[n + 1]
            shapley_vals[i] += Float64(weight) * (imbalances[c] - imbalance_without_i)
        end
    end
    return shapley_vals
end

function check_stability(payoffs, coalition_values, clients)
    # This function checks the stability of the coalition by comparing the excess of each coalition
    # Instead of generating combinations, iterate through all coalitions in coalition_values
    grand_coalition_set = Set(clients)
    
    # Checks how the value of a coalition compares to their reward as part of the grand coalition
    instabilities = Dict()
    for (coalition, value) in coalition_values
        # Skip the grand coalition and empty coalition
        coalition_set = Set(coalition)
        if coalition_set == grand_coalition_set || isempty(coalition_set)
            continue
        end

        # Calculate excess for this coalition
        instabilities[coalition] = value - sum(payoffs[i] for i in coalition)
    end
    
    # Return the maximum instability (excess)
    if isempty(instabilities)
        return 0.0
    end
    max_instability = maximum(values(instabilities))
    
    return max_instability
end

function simple_MCC(clients, coalitionCosts)
    # This function calculates the MCC (marginal cost contribution) value for each client in the grand coalition
    grand_coalition = vec(clients)
    grand_coalition_cost = coalitionCosts[grand_coalition]
    utilities = Dict{String, Float64}()
    for client in clients
        coalition_wo_client = filter(x -> x != client, grand_coalition)
        coalition_value_wo_client = coalitionCosts[coalition_wo_client]
        # Calculate the MCC value for the client
        MCC_value = (grand_coalition_cost - coalition_value_wo_client)
        # Store the MCC value in a dictionary
        utilities[client] = MCC_value
    end
    return utilities
end

function MCC_BB(clients, coalitionCosts)
    # This function calculates the MCC value for each client in the grand coalition
    # Handles budget balanced case by optimizing
    mcc_payments = simple_MCC(clients, coalitionCosts)
    if sum(values(mcc_payments)) == coalitionCosts[clients]
        # If the MCC payments are budget balanced, return them as is
        return mcc_payments
    end
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, payment[clients])

    # Objective is to minimize the squared relative difference from MCC payments
    @objective(model, Min, sum(((mcc_payments[client] - payment[client])/(mcc_payments[client]))^2 for client in clients))

    # Constraint to ensure budget balance
    @constraint(model, sum(payment) == coalitionCosts[clients])

    # Constraints to ensure individual rationality
    @constraint(model, [client in clients],
                payment[client] <= coalitionCosts[[client]]) # Payments must be lower than solo payment

    # Constraint to ensure no one pays less than their utopian allocation
    @constraint(model, [client in clients],
                payment[client] >= mcc_payments[client])

    optimize!(model)

    if termination_status(model) != MOI.OPTIMAL
        error("MCC optimization failed: $(termination_status(model))")
    end

    optimized_payments = Dict{String, Float64}()
    for client in clients
        optimized_payments[client] = value(payment[client])
    end

    return optimized_payments
end

function gately_point(clients, imbalance_costs)
    # This function calculates the Gately point for the given clients and their imbalance costs
    A = length(clients)
    # List of costs of coalitions of length A-1
    v_without = [imbalance_costs[filter(x -> x != client, clients)] for client in clients]
    v = [imbalance_costs[[client]] for client in clients]
    total_imbalance = imbalance_costs[clients]
    gately_distribution = Dict{String, Float64}()

    # Finding propensity to disrupt with the closed form solution
    d = ((A-1)*total_imbalance-sum(v_without))/(total_imbalance-sum(v))
    if isnan(d) || isinf(d)
        #println("d is NaN or infinite")
        #println("Likely cause: all imbalances have the same sign, or no imbalance at all")
        #println("Returning solitary client imbalance costs")
        for (idx, client) in enumerate(clients)
            gately_distribution[client] = v[idx]
            #println("Client: ", client, ", Gately distribution: ", gately_distribution[client])
        end
        return gately_distribution
    end

    # Calculating allocation using the found propensity to disrupt
    for (idx,client) in enumerate(clients)
        # d = ((total_imbalance-v_without(client)) - x)/(x-v[client])        
        gately_distribution[client] = (d*v[idx] + total_imbalance - v_without[idx]) / (d + 1)
    end

    return gately_distribution
end

function gately_point_interval(clients, imbalancesDict, systemData)
    # This function applies the Gately point calculation monthly
    # Adapted for two-price system: only costs when imbalance is in dominant direction
    T = length(imbalancesDict[[clients[1]]])
    grandCoalition = vec(clients)
    gately_distribution = Dict(client => 0.0 for client in clients)

    # Get time series data
    imbalance_spread = systemData["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominantDirection = systemData["price_prod_demand_df"][!, "DominatingDirection"]
    datetimes = systemData["price_prod_demand_df"][!, "HourUTC_datetime"]
    
    # Group intervals by month (year-month)
    months = unique(Dates.yearmonth.(datetimes))
    
    for month in months
        # Find all intervals belonging to this month
        month_indices = findall(x -> Dates.yearmonth(x) == month, datetimes)
        
        if isempty(month_indices)
            continue
        end
        
        # Calculate monthly costs for each coalition
        ImbalanceCosts = Dict{Vector{String}, Float64}()
        
        # Calculate costs for the grand coalition
        monthly_cost = 0.0
        for t in month_indices
            tempImbalance = imbalancesDict[grandCoalition][t]
            imbalance_cost = tempImbalance * imbalance_spread[t]
            # Two-price: only keep costs (negative values), zero out income (positive values)
            monthly_cost += min(0.0, imbalance_cost)
        end
        ImbalanceCosts[grandCoalition] = monthly_cost
        
        # Calculate costs for each client
        for client in clients
            monthly_cost = 0.0
            for t in month_indices
                tempImbalance = imbalancesDict[[client]][t]
                imbalance_cost = tempImbalance * imbalance_spread[t]
                monthly_cost += min(0.0, imbalance_cost)
            end
            ImbalanceCosts[[client]] = monthly_cost
            
            # Calculate for grand coalition minus the client
            GCMinusClient = filter(c -> c != client, grandCoalition)
            monthly_cost = 0.0
            for t in month_indices
                tempImbalance = sum(imbalancesDict[[c]][t] for c in GCMinusClient)
                imbalance_cost = tempImbalance * imbalance_spread[t]
                monthly_cost += min(0.0, imbalance_cost)
            end
            ImbalanceCosts[GCMinusClient] = monthly_cost
        end

        # Calculate Gately point for this month and add to the distribution
        gately_monthly = gately_point(clients, ImbalanceCosts)
        # Check for NaN values in the Gately distribution for this month
        if any(isnan, values(gately_monthly))
            println("Warning: NaN detected in Gately distribution for month $month.")
        end
        for client in clients
            gately_distribution[client] += gately_monthly[client]
        end
    end
    
    return gately_distribution
end

function full_cost_transfer(clients, imbalanceDict, systemData)
    # Applies a uniform pricing redistribution of the grand coalition income gains
    # Adapted to work with income-based calculations instead of costs
    grand_coalition = vec(clients)
    imbalanceSpread = systemData["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominantDirection = systemData["price_prod_demand_df"][!, "DominatingDirection"]
    clientIncome = Dict(client => 0.0 for client in clients)
    tempSum = Dict(client => 0.0 for client in clients)

    for t in 1:length(imbalanceDict[[clients[1]]])
        
        tCostOfImbalance = imbalanceDict[grand_coalition][t] * imbalanceSpread[t]/sum(imbalanceDict[[c]][t] for c in clients)
        if imbalanceDict[grand_coalition][t] * dominantDirection[t] >= 0
            # No imbalance in the grand coalition in the dominant direction, skip this time step
            continue
        end
        for client in clients
            client_imbalance = imbalanceDict[[client]][t]
            clientIncome[client] += client_imbalance * tCostOfImbalance 
        end
    end
    
    return clientIncome
end

function reduced_cost(clients, imbalancesDict, systemData)
    # Allocates the reduced cost to cost causers
    # Cost reducers do not get compensation
    grand_coalition = vec(clients)
    imbalanceSpread = systemData["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominatingDirection = systemData["price_prod_demand_df"][!, "DominatingDirection"]
    client_cost = Dict(client => 0.0 for client in clients)
    
    for t in 1:length(imbalancesDict[[clients[1]]])
        # Calculate the total imbalance for the grand coalition
        grand_coalition_imbalance = imbalancesDict[grand_coalition][t]
        
        # Calculate the cost for the grand coalition
        grandCoalitionCost = 0.0
        if grand_coalition_imbalance * dominatingDirection[t] > 0
            grandCoalitionCost = grand_coalition_imbalance * imbalanceSpread[t]
        else
            # If the grand coalition has no imbalance in the dominant direction, skip this time step
            continue
        end
        # Getting the total imbalance in the dominant direction
        singletonImbalance = sum(imbalancesDict[[client]][t] for client in clients if imbalancesDict[[client]][t] * dominatingDirection[t] > 0)
        
        # Distribute costs to clients based on their imbalances
        for client in clients
            client_imbalance = imbalancesDict[[client]][t]
            if client_imbalance * dominatingDirection[t] > 0
                # Client has an imbalance in the dominant direction
                client_cost[client] += ((client_imbalance) / (singletonImbalance)) * grandCoalitionCost
            end
        end
    end

    return client_cost
end

function nucleolus(clients, imbalances)
    # Optimized nucleolus computation with reduced memory allocations
    n_clients = length(clients)
    coalitions = collect(combinations(clients))
    n_coalitions = length(coalitions)
    
    # Pre-allocate and cache coalition indices for faster access
    client_to_idx = Dict(client => i for (i, client) in enumerate(clients))
    coalition_indices = Vector{Vector{Int}}(undef, n_coalitions)
    
    # Build coalition indices and imbalances vector more efficiently
    imbalances_vec = Vector{Float64}(undef, n_coalitions)
    GC.gc()  # Force garbage collection to reduce memory fragmentation
    for (i, coalition) in enumerate(coalitions)
        # Convert client names to indices for faster constraint building
        coalition_indices[i] = [client_to_idx[client] for client in coalition]
        
        # Look up imbalance value with fallback
        if haskey(imbalances, coalition)
            imbalances_vec[i] = imbalances[coalition]
        else
            # Try as sorted tuple (more efficient than collect)
            sorted_coalition = sort(coalition)
            imbalances_vec[i] = get(imbalances, sorted_coalition, 0.0)
        end
    end
    
    # Use BitVector for locked status - much more memory efficient than Union{Nothing, Float64}
    locked_status = falses(n_coalitions)
    locked_values = zeros(Float64, n_coalitions)
    
    # Find grand coalition index once
    grand_coalition_idx = findfirst(c -> length(c) == n_clients, coalitions)
    
    payments = Dict{String, Float64}()
    max_iterations = n_coalitions  # Prevent infinite loops
    iteration = 0
    
    while iteration < max_iterations
        iteration += 1
        
        try
            max_excess, new_locked_indices, new_payments = nucleolus_optimize(
                n_clients, imbalances_vec, locked_status, locked_values, 
                coalition_indices, grand_coalition_idx
            )
            
            # Update locked status efficiently
            for idx in new_locked_indices
                locked_status[idx] = true
                locked_values[idx] = max_excess
            end
            
            # Update payments
            for (i, client) in enumerate(clients)
                payments[client] = new_payments[i]
            end
            
            # Check if we're done (all coalitions except grand coalition are locked)
            if count(locked_status) >= n_coalitions - 1
                break
            end
            
        catch e
            if count(locked_status) >= n_coalitions - 1
                # Return current solution
                locked_dict = Dict{Vector{String}, Float64}()
                for (i, coalition) in enumerate(coalitions)
                    if locked_status[i]
                        locked_dict[coalition] = locked_values[i]
                    end
                end
                return locked_dict, payments
            else
                println("Nucleolus optimization failed: ", e)
                return nothing, nothing
            end
        end
    end
    
    # Build final locked dictionary
    locked_dict = Dict{Vector{String}, Float64}()
    for (i, coalition) in enumerate(coalitions)
        if locked_status[i]
            locked_dict[coalition] = locked_values[i]
        end
    end
    
    return locked_dict, payments
end

function nucleolus_optimize(n_clients, imbalances_vec, locked_status, locked_values, 
                                coalition_indices, grand_coalition_idx)
    n_coalitions = length(coalition_indices)
    
    # Create model
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    
    # Set HiGHS-specific parameters for better performance
    #set_optimizer_attribute(model, "presolve", "on")
    #set_optimizer_attribute(model, "parallel", "on")
    
    @variable(model, payment[1:n_clients])
    @variable(model, max_excess)
    @objective(model, Min, max_excess)
    
    # Precomputing unlocked coalitions
    unlocked_coalitions = findall(i -> !locked_status[i] && i != grand_coalition_idx, 1:n_coalitions)
    
    # Excess constraints only for unlocked coalitions (excluding grand coalition)
    @constraint(model, excess_cons[i in unlocked_coalitions],
                imbalances_vec[i] - sum(payment[j] for j in coalition_indices[i]) <= max_excess)
    
    # Grand coalition constraint (budget balance)
    @constraint(model, sum(payment) == imbalances_vec[grand_coalition_idx])
    
    # Locked coalition constraints
    locked_coalitions = findall(locked_status)
    @constraint(model, [i in locked_coalitions],
                sum(payment[j] for j in coalition_indices[i]) - imbalances_vec[i] == locked_values[i])
    
    optimize!(model)
    
    if termination_status(model) == MOI.OPTIMAL
        payment_values = value.(payment)
        max_excess_val = objective_value(model)
        
        # Find coalitions that achieve maximum excess
        new_locked_indices = Int[]
        tol = 1e-8 
        
        for i in unlocked_coalitions
            excess_val = sum(payment_values[j] for j in coalition_indices[i]) - imbalances_vec[i]
            if abs(excess_val - max_excess_val) < tol
                push!(new_locked_indices, i)
            end
        end
        
        return max_excess_val, new_locked_indices, payment_values
    else
        error("No optimal solution found in nucleolus optimization")
    end
end

function flat_rate_allocation(clients, coalitionCosts, systemData)
    # This function calculates the imbalance cost per MWh and allocates it evenly to all clients
    # This is roughly equivalent to the system currently in place
    allocation = Dict{String, Float64}()
    total_costs = coalitionCosts[clients]
    total_demand = sum(sum(systemData["price_prod_demand_df"][!, client]) for client in clients)
    flat_rate = total_costs / total_demand
    for client in clients
        allocation[client] = flat_rate * sum(systemData["price_prod_demand_df"][!, client])
    end
    return allocation
end

function scaled_allocation(clients, coalitionCosts)
    # This function calculates the aggregated vs unaggregated cost and multiplies individual costs by the ratio
    allocation = Dict{String, Float64}()
    
    # Calculate total aggregated cost (grand coalition)
    aggregated_cost = coalitionCosts[clients]
    
    # Calculate total unaggregated cost (sum of individual costs)
    unaggregated_cost = sum(coalitionCosts[[client]] for client in clients)
    
    # Calculate the scaling ratio (aggregated vs unaggregated)
    scaling_ratio = aggregated_cost / unaggregated_cost
    if isnan(scaling_ratio) || isinf(scaling_ratio)
        scaling_ratio = 1.0
    end
    # Scale each client's individual cost by the ratio
    for client in clients
        allocation[client] = coalitionCosts[[client]] * scaling_ratio
    end
    
    return allocation
end
