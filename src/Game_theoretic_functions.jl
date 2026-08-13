using Combinatorics, HiGHS, JuMP#, NLsolve,

# Sign convention: allocation-mechanism functions below return per-client costs, where
# positive means the client owes money (matching coalition_costs, which is <= 0 per
# coalition under the two-price clamp in calculate_total_costs_specific). The one exception
# is marginal_price_allocation, which returns net transfers: a client whose individual imbalance
# opposed the coalition's net imbalance in a given hour can legitimately receive a net
# subsidy (a positive value) rather than a cost.
function calculate_allocations(
    allocations, clients, coalition_costs, coalition_imbalances, system_data; printing = true, return_time = false
    )
    allocation_times = Dict{String, Float64}()
    allocation_costs = Dict{String, Any}()
    allocation_map = Dict(
        "shapley" => () -> shapley_value(clients, coalition_costs),
        "MCC" => () -> mcc_allocation(clients, coalition_costs),
        "MCC_budget_balanced" => () -> mcc_budget_balanced_allocation(clients, coalition_costs),
        "VCG" => () -> deepcopy(vcg_allocation(clients, coalition_costs, coalition_imbalances, system_data)),
        "gately" => () -> deepcopy(gately_allocation(clients, coalition_costs)),
        "gately_interval" => () -> deepcopy(gately_interval_allocation(clients, coalition_imbalances, system_data)),
        "marginal_price" => () -> deepcopy(marginal_price_allocation(clients, coalition_imbalances, system_data)),
        "reduced_cost" => () -> deepcopy(reduced_cost_allocation(clients, coalition_imbalances, system_data)),
        "nucleolus" => () -> begin
            _, nucleolus_values = nucleolus(clients, coalition_costs)
            deepcopy(nucleolus_values)
        end,
        "equal_share" => () -> deepcopy(equal_share_allocation(clients, coalition_costs)),
        "flat_rate" => () -> deepcopy(flat_rate_allocation(clients, coalition_costs, system_data)),
        "scaled" => () -> deepcopy(scaled_allocation(clients, coalition_costs))
    )
    allocation_print_map = Dict(
        "shapley" => "Shapley calculation time:",
        "MCC" => "MCC calculation time:",
        "MCC_budget_balanced" => "MCC budget balanced calculation time:",
        "VCG" => "VCG calculation time:",
        "gately" => "Gately calculation time:",
        "gately_interval" => "Gately calculation time, interval:",
        "marginal_price" => "Marginal price transfer calculation time:",
        "reduced_cost" => "Reduced cost calculation time:",
        "nucleolus" => "Nucleolus calculation time:",
        "equal_share" => "Equal share calculation time:",
        "flat_rate" => "Flat rate calculation time:",
        "scaled" => "Scaled allocation calculation time:"
    )
    for allocation in allocations
        if haskey(allocation_map, allocation)
            # Compute once and time that single computation (previously this recomputed
            # every mechanism a second time via @elapsed just to measure return_time,
            # discarding the first pass's result).
            elapsed = @elapsed (result = allocation_map[allocation]())
            allocation_costs[allocation] = result
            allocation_times[allocation] = elapsed
            if printing && haskey(allocation_print_map, allocation)
                println(allocation_print_map[allocation], " ", round(elapsed, digits=4), " s")
            end
        end
    end
    if return_time
        return allocation_costs, allocation_times
    end
    return allocation_costs
end

function shapley_value(clients, coalition_costs)
    # This function calculates the Shapley value for each client in the grand coalition
    n = length(clients)
    shapley_vals = Dict()
    coalitions = collect(combinations(clients))
    for client in clients
        shapley_vals[client] = 0.0
    end

    # Precompute factorials to avoid repeated calculations
    if n > 20
        # Use BigInt for large factorials to avoid Int64 overflow (21! exceeds typemax(Int64))
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
                cost_without_i = 0.0
            else
                cost_without_i = coalition_costs[c_without_i]
            end
            # Calculate the Shapley value contribution for client i in coalition c
            # Use precomputed factorials
            weight = factorials[S] * factorials[n - S + 1] / factorials[n + 1]
            shapley_vals[i] += Float64(weight) * (coalition_costs[c] - cost_without_i)
        end
    end
    return shapley_vals
end

function check_stability(client_costs, coalition_costs, clients)
    # This function checks the stability of the coalition by comparing the excess of each coalition
    # Instead of generating combinations, iterate through all coalitions in coalition_costs
    grand_coalition_set = Set(clients)

    # Checks how the value of a coalition compares to their reward as part of the grand coalition
    instabilities = Dict()
    for (coalition, coalition_cost) in coalition_costs
        # Skip the grand coalition and empty coalition
        coalition_set = Set(coalition)
        if coalition_set == grand_coalition_set || isempty(coalition_set)
            continue
        end

        # Calculate excess for this coalition
        instabilities[coalition] = coalition_cost - sum(client_costs[i] for i in coalition)
    end

    # Return the maximum instability (excess)
    if isempty(instabilities)
        return 0.0
    end
    max_instability = maximum(values(instabilities))

    return max_instability
end

function mcc_allocation(clients, coalition_costs)
    # This function calculates the MCC (marginal cost contribution) value for each client in the grand coalition
    grand_coalition = vec(clients)
    grand_coalition_cost = coalition_costs[grand_coalition]
    client_costs = Dict{String, Float64}()
    for client in clients
        coalition_wo_client = filter(x -> x != client, grand_coalition)
        coalition_cost_wo_client = coalition_costs[coalition_wo_client]
        # Calculate the MCC value for the client
        mcc_value = (grand_coalition_cost - coalition_cost_wo_client)
        # Store the MCC value in a dictionary
        client_costs[client] = mcc_value
    end
    return client_costs
end

function mcc_budget_balanced_allocation(clients, coalition_costs)
    # This function calculates the MCC value for each client in the grand coalition
    # Handles budget balanced case by optimizing
    mcc_payments = mcc_allocation(clients, coalition_costs)
    if sum(values(mcc_payments)) == coalition_costs[clients]
        # If the MCC payments are budget balanced, return them as is
        return mcc_payments
    end
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, payment[clients])

    # Objective is to minimize the squared relative difference from MCC payments
    @objective(model, Min, sum(((mcc_payments[client] - payment[client])/(mcc_payments[client]))^2 for client in clients))

    # Constraint to ensure budget balance
    @constraint(model, sum(payment) == coalition_costs[clients])

    # Constraints to ensure individual rationality
    @constraint(model, [client in clients],
                payment[client] <= coalition_costs[[client]]) # Payments must be lower than solo payment

    # Constraint to ensure no one pays less than their utopian allocation
    @constraint(model, [client in clients],
                payment[client] >= mcc_payments[client])

    optimize!(model)

    if termination_status(model) != MOI.OPTIMAL
        error("MCC optimization failed: $(termination_status(model))")
    end

    client_costs = Dict{String, Float64}()
    for client in clients
        client_costs[client] = value(payment[client])
    end

    return client_costs
end

function gately_allocation(clients, coalition_costs)
    # This function calculates the Gately point for the given clients and their coalition costs
    A = length(clients)
    # List of costs of coalitions of length A-1
    v_without = [coalition_costs[filter(x -> x != client, clients)] for client in clients]
    v = [coalition_costs[[client]] for client in clients]
    total_cost = coalition_costs[clients]
    client_costs = Dict{String, Float64}()

    # Finding propensity to disrupt with the closed form solution
    d = ((A-1)*total_cost-sum(v_without))/(total_cost-sum(v))
    if isnan(d) || isinf(d)
        # d is NaN or infinite when all coalition costs have the same sign, or there's no cost
        # at all (total_cost == sum(v)); fall back to each client's own solo cost.
        for (idx, client) in enumerate(clients)
            client_costs[client] = v[idx]
        end
        return client_costs
    end

    # Calculating allocation using the found propensity to disrupt
    for (idx,client) in enumerate(clients)
        # d = ((total_cost-v_without(client)) - x)/(x-v[client])
        client_costs[client] = (d*v[idx] + total_cost - v_without[idx]) / (d + 1)
    end

    return client_costs
end

function gately_interval_allocation(clients, coalition_imbalances, system_data)
    # This function applies the Gately point calculation month by month and sums the result
    T = length(coalition_imbalances[[clients[1]]])
    grand_coalition = vec(clients)
    client_costs = Dict(client => 0.0 for client in clients)

    # Get time series data
    imbalance_spread = system_data["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    datetimes = system_data["price_prod_demand_df"][!, "HourUTC_datetime"]

    # Group intervals by month (year-month)
    months = unique(Dates.yearmonth.(datetimes))

    for month in months
        # Find all intervals belonging to this month
        month_indices = findall(x -> Dates.yearmonth(x) == month, datetimes)

        if isempty(month_indices)
            continue
        end

        # Calculate monthly costs for each coalition
        imbalance_costs = Dict{Vector{String}, Float64}()

        # Calculate costs for the grand coalition
        monthly_cost = 0.0
        for t in month_indices
            temp_imbalance = coalition_imbalances[grand_coalition][t]
            imbalance_cost = temp_imbalance * imbalance_spread[t]
            # Two-price: only keep costs (negative values), zero out income (positive values)
            monthly_cost += min(0.0, imbalance_cost)
        end
        imbalance_costs[grand_coalition] = monthly_cost

        # Calculate costs for each client
        for client in clients
            monthly_cost = 0.0
            for t in month_indices
                temp_imbalance = coalition_imbalances[[client]][t]
                imbalance_cost = temp_imbalance * imbalance_spread[t]
                monthly_cost += min(0.0, imbalance_cost)
            end
            imbalance_costs[[client]] = monthly_cost

            # Calculate for grand coalition minus the client
            grand_coalition_minus_client = filter(c -> c != client, grand_coalition)
            monthly_cost = 0.0
            for t in month_indices
                temp_imbalance = sum(coalition_imbalances[[c]][t] for c in grand_coalition_minus_client)
                imbalance_cost = temp_imbalance * imbalance_spread[t]
                monthly_cost += min(0.0, imbalance_cost)
            end
            imbalance_costs[grand_coalition_minus_client] = monthly_cost
        end

        # Calculate Gately point for this month and add to the distribution
        gately_monthly = gately_allocation(clients, imbalance_costs)
        # Check for NaN values in the Gately distribution for this month
        if any(isnan, values(gately_monthly))
            println("Warning: NaN detected in Gately distribution for month $month.")
        end
        for client in clients
            client_costs[client] += gately_monthly[client]
        end
    end

    return client_costs
end

function vcg_allocation(clients, coalition_costs, coalition_imbalances, system_data)
    # Implements the VCG mechanism: charges each client the externality its presence
    # imposes on the rest of the grand coalition, i.e. what N\{i} would pay if priced at
    # the grand coalition's own two-price spread, minus what N\{i} actually pays alone.
    grand_coalition = vec(clients)
    imbalance_spread = system_data["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominant_direction = system_data["price_prod_demand_df"][!, "DominantDirection"]
    grand_imbalance = coalition_imbalances[grand_coalition]
    T = length(grand_imbalance)

    client_costs = Dict{String, Float64}()
    for client in clients
        coalition_wo_client = filter(x -> x != client, grand_coalition)
        imbalance_wo_client = coalition_imbalances[coalition_wo_client]
        externality = 0.0
        for t in 1:T
            if grand_imbalance[t] * dominant_direction[t] < 0
                # Grand coalition harms the system this hour: price N\{i}'s imbalance at the grand-coalition spread
                externality += imbalance_wo_client[t] * imbalance_spread[t]
            end
        end
        client_costs[client] = externality - coalition_costs[coalition_wo_client]
    end
    return client_costs
end

function marginal_price_allocation(clients, coalition_imbalances, system_data)
    # Applies a uniform pricing redistribution of the grand coalition's cost.
    # Returns net transfers, not strictly costs: a client whose individual imbalance opposed
    # the coalition's net imbalance in a given hour can receive a net subsidy (a positive
    # value) rather than a cost, unlike the other allocation mechanisms in this file.
    grand_coalition = vec(clients)
    imbalance_spread = system_data["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominant_direction = system_data["price_prod_demand_df"][!, "DominantDirection"]
    client_transfers = Dict(client => 0.0 for client in clients)

    for t in 1:length(coalition_imbalances[[clients[1]]])

        t_cost_of_imbalance = coalition_imbalances[grand_coalition][t] * imbalance_spread[t]/sum(coalition_imbalances[[c]][t] for c in clients)
        if coalition_imbalances[grand_coalition][t] * dominant_direction[t] >= 0
            # No imbalance in the grand coalition in the dominant direction, skip this time step
            continue
        end
        for client in clients
            client_imbalance = coalition_imbalances[[client]][t]
            client_transfers[client] += client_imbalance * t_cost_of_imbalance
        end
    end

    return client_transfers
end

function reduced_cost_allocation(clients, coalition_imbalances, system_data)
    # Allocates the reduced cost to cost causers
    # Cost reducers do not get compensation
    grand_coalition = vec(clients)
    imbalance_spread = system_data["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominant_direction = system_data["price_prod_demand_df"][!, "DominantDirection"]
    client_costs = Dict(client => 0.0 for client in clients)

    for t in 1:length(coalition_imbalances[[clients[1]]])
        # Calculate the total imbalance for the grand coalition
        grand_coalition_imbalance = coalition_imbalances[grand_coalition][t]

        # Calculate the cost for the grand coalition
        grand_coalition_cost = 0.0
        if grand_coalition_imbalance * dominant_direction[t] > 0
            grand_coalition_cost = grand_coalition_imbalance * imbalance_spread[t]
        else
            # If the grand coalition has no imbalance in the dominant direction, skip this time step
            continue
        end
        # Getting the total imbalance in the dominant direction
        singleton_imbalance = sum(coalition_imbalances[[client]][t] for client in clients if coalition_imbalances[[client]][t] * dominant_direction[t] > 0)

        # Distribute costs to clients based on their imbalances
        for client in clients
            client_imbalance = coalition_imbalances[[client]][t]
            if client_imbalance * dominant_direction[t] > 0
                # Client has an imbalance in the dominant direction
                client_costs[client] += ((client_imbalance) / (singleton_imbalance)) * grand_coalition_cost
            end
        end
    end

    return client_costs
end

function nucleolus(clients, coalition_costs)
    # Optimized nucleolus computation with reduced memory allocations
    n_clients = length(clients)
    coalitions = collect(combinations(clients))
    n_coalitions = length(coalitions)

    # Pre-allocate and cache coalition indices for faster access
    client_to_idx = Dict(client => i for (i, client) in enumerate(clients))
    coalition_indices = Vector{Vector{Int}}(undef, n_coalitions)

    # Build coalition indices and coalition-cost vector more efficiently
    coalition_costs_vec = Vector{Float64}(undef, n_coalitions)
    for (i, coalition) in enumerate(coalitions)
        # Convert client names to indices for faster constraint building
        coalition_indices[i] = [client_to_idx[client] for client in coalition]

        # Look up coalition cost with fallback
        if haskey(coalition_costs, coalition)
            coalition_costs_vec[i] = coalition_costs[coalition]
        else
            # Try as sorted tuple (more efficient than collect)
            sorted_coalition = sort(coalition)
            coalition_costs_vec[i] = get(coalition_costs, sorted_coalition, 0.0)
        end
    end

    # Use BitVector for locked status - much more memory efficient than Union{Nothing, Float64}
    locked_status = falses(n_coalitions)
    locked_values = zeros(Float64, n_coalitions)

    # Find grand coalition index once
    grand_coalition_idx = findfirst(c -> length(c) == n_clients, coalitions)

    client_costs = Dict{String, Float64}()
    max_iterations = n_coalitions  # Prevent infinite loops
    iteration = 0

    while iteration < max_iterations
        iteration += 1

        try
            max_excess, new_locked_indices, new_client_costs = nucleolus_optimize(
                n_clients, coalition_costs_vec, locked_status, locked_values,
                coalition_indices, grand_coalition_idx
            )

            # Update locked status efficiently
            for idx in new_locked_indices
                locked_status[idx] = true
                locked_values[idx] = max_excess
            end

            # Update client costs
            for (i, client) in enumerate(clients)
                client_costs[client] = new_client_costs[i]
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
                return locked_dict, client_costs
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

    return locked_dict, client_costs
end

function nucleolus_optimize(n_clients, coalition_costs_vec, locked_status, locked_values,
                                coalition_indices, grand_coalition_idx)
    n_coalitions = length(coalition_indices)

    # Create model
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, payment[1:n_clients])
    @variable(model, max_excess)
    @objective(model, Min, max_excess)

    # Precomputing unlocked coalitions
    unlocked_coalitions = findall(i -> !locked_status[i] && i != grand_coalition_idx, 1:n_coalitions)

    # Excess constraints only for unlocked coalitions (excluding grand coalition)
    @constraint(model, excess_cons[i in unlocked_coalitions],
                coalition_costs_vec[i] - sum(payment[j] for j in coalition_indices[i]) <= max_excess)

    # Grand coalition constraint (budget balance)
    @constraint(model, sum(payment) == coalition_costs_vec[grand_coalition_idx])

    # Locked coalition constraints
    locked_coalitions = findall(locked_status)
    @constraint(model, [i in locked_coalitions],
                sum(payment[j] for j in coalition_indices[i]) - coalition_costs_vec[i] == locked_values[i])

    optimize!(model)

    if termination_status(model) == MOI.OPTIMAL
        payment_values = value.(payment)
        max_excess_val = objective_value(model)

        # Find coalitions that achieve maximum excess
        new_locked_indices = Int[]
        tol = 1e-8

        for i in unlocked_coalitions
            excess_val = sum(payment_values[j] for j in coalition_indices[i]) - coalition_costs_vec[i]
            if abs(excess_val - max_excess_val) < tol
                push!(new_locked_indices, i)
            end
        end

        return max_excess_val, new_locked_indices, payment_values
    else
        error("No optimal solution found in nucleolus optimization")
    end
end

function flat_rate_allocation(clients, coalition_costs, system_data)
    # This function calculates the imbalance cost per MWh and allocates it evenly to all clients
    # This is roughly equivalent to the system currently in place
    client_costs = Dict{String, Float64}()
    total_costs = coalition_costs[clients]
    total_demand = sum(sum(system_data["price_prod_demand_df"][!, client]) for client in clients)
    flat_rate = total_costs / total_demand
    for client in clients
        client_costs[client] = flat_rate * sum(system_data["price_prod_demand_df"][!, client])
    end
    return client_costs
end

function scaled_allocation(clients, coalition_costs)
    # This function calculates the aggregated vs unaggregated cost and multiplies individual costs by the ratio
    client_costs = Dict{String, Float64}()

    # Calculate total aggregated cost (grand coalition)
    aggregated_cost = coalition_costs[clients]

    # Calculate total unaggregated cost (sum of individual costs)
    unaggregated_cost = sum(coalition_costs[[client]] for client in clients)

    # Calculate the scaling ratio (aggregated vs unaggregated)
    scaling_ratio = aggregated_cost / unaggregated_cost
    if isnan(scaling_ratio) || isinf(scaling_ratio)
        scaling_ratio = 1.0
    end
    # Scale each client's individual cost by the ratio
    for client in clients
        client_costs[client] = coalition_costs[[client]] * scaling_ratio
    end

    return client_costs
end

function equal_share_allocation(clients, coalition_costs)
    # This function splits the coalition cost evenly across all clients
    # Budget-balanced by construction: sum(values) == coalition_costs[clients]
    client_costs = Dict{String, Float64}()
    total_cost = coalition_costs[clients]
    n = length(clients)
    share = total_cost / n
    for client in clients
        client_costs[client] = share
    end
    return client_costs
end
