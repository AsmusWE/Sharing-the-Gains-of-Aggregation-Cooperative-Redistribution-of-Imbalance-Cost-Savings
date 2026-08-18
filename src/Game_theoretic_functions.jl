using Combinatorics, HiGHS, JuMP, LinearAlgebra#, NLsolve,

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
    # Nucleolus via sequential LP peeling, with several optimizations over the naive version:
    #  - coalitions are indexed by bitmask instead of Vector{String}, so cost/membership
    #    lookups are array indexing rather than hashing string vectors
    #  - the JuMP/HiGHS model is built once and kept alive across iterations; a coalition
    #    that locks has its `<= max_excess` inequality swapped in place for an equality
    #    constraint, so HiGHS can warm-start each solve from the previous basis instead of
    #    resolving cold every iteration
    #  - the loop stops as soon as the locked coalitions' indicator vectors (together with
    #    the budget-balance row) span R^n_clients, since the payment vector is then already
    #    uniquely determined and cannot change no matter how many coalitions remain unlocked
    #  - each iteration's dual scan only visits coalitions that are still unlocked (a shrinking
    #    active set), instead of re-walking every one of the n_coalitions masks on every
    #    iteration -- on degenerate real-world instances where most lock events don't raise the
    #    rank, iteration counts can themselves approach n_coalitions, so an unconditional
    #    per-iteration O(n_coalitions) rescan turns into O(n_coalitions^2) overall
    #  - the "does the locked set span R^n_clients yet" check maintains a small incrementally
    #    updated orthonormal basis (Gram-Schmidt, capped at n_clients rows) instead of appending
    #    every locked row to a growing matrix and recomputing a full SVD-based rank() from
    #    scratch each iteration -- the same degenerate-instance blowup as above otherwise applies
    #    to both the vcat and the rank() call
    n_clients = length(clients)
    n_coalitions = 2^n_clients - 1  # all nonempty subsets of clients, including the grand coalition
    grand_mask = n_coalitions        # all bits set = grand coalition

    coalition_indices = Vector{Vector{Int}}(undef, n_coalitions)
    coalition_costs_vec = Vector{Float64}(undef, n_coalitions)
    for mask in 1:n_coalitions
        indices = [j for j in 1:n_clients if (mask >> (j - 1)) & 1 == 1]
        coalition_indices[mask] = indices
        coalition = [clients[j] for j in indices]
        if haskey(coalition_costs, coalition)
            coalition_costs_vec[mask] = coalition_costs[coalition]
        else
            coalition_costs_vec[mask] = get(coalition_costs, sort(coalition), 0.0)
        end
    end

    locked_status = falses(n_coalitions)
    locked_values = zeros(Float64, n_coalitions)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, payment[1:n_clients])
    @variable(model, max_excess)
    @objective(model, Min, max_excess)
    @constraint(model, sum(payment) == coalition_costs_vec[grand_mask])

    # Each non-grand coalition starts as an inequality constraint; coalition_constraints[mask]
    # holds whichever constraint (inequality or, once locked, equality) currently represents it.
    coalition_constraints = Vector{Any}(undef, n_coalitions)
    for mask in 1:n_coalitions
        mask == grand_mask && continue
        coalition_constraints[mask] = @constraint(model,
            coalition_costs_vec[mask] - sum(payment[j] for j in coalition_indices[mask]) <= max_excess)
    end

    # Masks still awaiting a lock decision; shrinks as coalitions lock so the dual scan below
    # never revisits an already-locked (or grand) coalition.
    active_masks = [mask for mask in 1:n_coalitions if mask != grand_mask]

    # Incrementally-maintained orthonormal basis (Gram-Schmidt) of locked coalitions' indicator
    # vectors, seeded with the budget-balance row (all ones); once basis_rank == n_clients, x is
    # uniquely pinned down. Capped at n_clients rows -- that's all that's ever needed to detect
    # full rank, so unlike the naive "grow a matrix and recompute rank(...) from scratch" this
    # never grows unbounded even if many locked rows turn out to be rank-redundant.
    rank_tol = 1e-8
    basis = zeros(Float64, n_clients, n_clients)
    basis_rank = 1
    basis[1, :] = fill(1.0 / sqrt(n_clients), n_clients)

    client_costs = Dict{String, Float64}()
    max_iterations = n_coalitions  # Prevent infinite loops
    iteration = 0
    dual_tol = 1e-7

    println("Nucleolus: $n_clients clients, $n_coalitions coalitions")
    flush(stdout)

    while iteration < max_iterations
        iteration += 1
        optimize!(model)

        if termination_status(model) != MOI.OPTIMAL
            if isempty(client_costs)
                println("Nucleolus optimization failed: ", termination_status(model))
                return nothing, nothing
            end
            break
        end

        payment_values = value.(payment)
        max_excess_val = objective_value(model)

        for (i, client) in enumerate(clients)
            client_costs[client] = payment_values[i]
        end

        # Find coalitions that are tight in EVERY optimal solution of this stage's LP, not
        # merely at the vertex HiGHS happened to return: when the stage LP is degenerate
        # (multiple optima achieve max_excess_val), some coalitions can be primally tied at
        # this particular vertex without being tied across the whole optimal face, and
        # locking those would wrongly exclude other, equally-optimal solutions from later
        # stages. A nonzero dual multiplier on a coalition's constraint is the correct test:
        # by complementary slackness, that coalition must be tight in every optimal solution.
        newly_locked = Int[]
        for mask in active_masks
            if abs(dual(coalition_constraints[mask])) > dual_tol
                push!(newly_locked, mask)
            end
        end
        # Full per-iteration logging gets unusably long on degenerate instances that take
        # thousands of iterations to converge, so only log every 500th iteration -- plus
        # unconditionally at each of the three ways the loop can end, so the log always shows
        # the actual final state rather than silently stopping mid-cadence.
        if iteration % 500 == 0 || isempty(newly_locked)
            println("Nucleolus iteration $iteration: max_excess = $(round(max_excess_val, digits=4)), locked = $(count(locked_status))/$(n_coalitions - 1), newly locked = $(length(newly_locked))")
            flush(stdout)
        end

        isempty(newly_locked) && break

        for mask in newly_locked
            locked_status[mask] = true
            locked_values[mask] = max_excess_val
            delete(model, coalition_constraints[mask])
            coalition_constraints[mask] = @constraint(model,
                coalition_costs_vec[mask] - sum(payment[j] for j in coalition_indices[mask]) == max_excess_val)

            if basis_rank < n_clients
                row = zeros(Float64, n_clients)
                for j in coalition_indices[mask]
                    row[j] = 1.0
                end
                for i in 1:basis_rank
                    row .-= dot(view(basis, i, :), row) .* view(basis, i, :)
                end
                row_norm = norm(row)
                if row_norm > rank_tol
                    basis_rank += 1
                    basis[basis_rank, :] = row ./ row_norm
                end
            end
        end

        filter!(m -> !locked_status[m], active_masks)

        # Check if we're done (all coalitions except grand coalition are locked)
        if count(locked_status) >= n_coalitions - 1
            println("Nucleolus: all coalitions locked after $iteration iterations (locked = $(count(locked_status))/$(n_coalitions - 1))")
            flush(stdout)
            break
        end

        # Check if the payment vector is already uniquely determined
        if basis_rank >= n_clients
            println("Nucleolus: payment vector uniquely determined after $iteration iterations (locked = $(count(locked_status))/$(n_coalitions - 1))")
            flush(stdout)
            break
        end
    end

    # Build final locked dictionary
    locked_dict = Dict{Vector{String}, Float64}()
    for mask in 1:n_coalitions
        if locked_status[mask]
            locked_dict[[clients[j] for j in coalition_indices[mask]]] = locked_values[mask]
        end
    end

    return locked_dict, client_costs
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
