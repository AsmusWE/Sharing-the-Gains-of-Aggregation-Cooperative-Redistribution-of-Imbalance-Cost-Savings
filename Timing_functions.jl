# Import the required functions from imbalance_functions.jl
include("imbalance_functions.jl")

function calculate_costs_timing(systemData, coalitions, stochasticData, T, imbalance_spread, dominantDirection)
    # Calculate imbalance costs for specific coalitions

    # Get all unique clients from all coalitions
    all_clients = unique(vcat(coalitions...))
    
    # Calculate bids for each individual client 
    individual_bids = Dict()
    for client in all_clients
        individual_bids[client] = optimize_imbalance([client], systemData, stochasticData)
    end
    
    # Pre-calculate actual demand and PV for each client
    actual_demand_per_client = Dict()
    actual_pv_per_client = Dict()
    for client in all_clients
        actual_demand_per_client[client] = systemData["price_prod_demand_df"][1:T, client]
        actual_pv_per_client[client] = systemData["price_prod_demand_df"][1:T, :SolarMWh] .* systemData["clientPVOwnership"][client]
    end
    
    # Calculate costs for each coalition by summing individual components
    costs_dict = Dict()
    abs_spread = abs.(imbalance_spread)  # Pre-compute absolute values
    
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
    end
    
    return costs_dict
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
    costs_dict = calculate_costs_timing(tempData, relevant_coalitions, stochasticData, T, imbalance_spread, dominantDirection)
    GC.gc()  # Force garbage collection to free memory
    return costs_dict
end

function costs_Gately(systemData, clients, startDay, days, stochasticData; printing=false)
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
    
    # Set up time period
    tempData = set_period!(systemData, startDay, days)
    T = size(tempData["price_prod_demand_df"], 1)
    imbalance_spread = tempData["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
    dominantDirection = tempData["price_prod_demand_df"][!, "DominatingDirection"]
    
    # Calculate costs for all relevant coalitions at once
    costs_dict = calculate_costs_timing(tempData, relevant_coalitions, stochasticData, T, imbalance_spread, dominantDirection)
    GC.gc()  # Force garbage collection to free memory
    return costs_dict
end