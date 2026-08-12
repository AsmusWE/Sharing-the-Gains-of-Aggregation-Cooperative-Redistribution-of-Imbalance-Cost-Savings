using Plots, Serialization, CSV, DataFrames
include("Game_theoretic_functions.jl")

function create_alphabetic_client_mapping(clients)
    # Create a mapping from original client names to alphabetic names (A, B, C, D...)
    alphabet = ['A':'Z';]
    mapping = Dict()
    for (i, client) in enumerate(clients)
        if i <= length(alphabet)
            mapping[client] = string(alphabet[i])
        else
            # For more than 26 clients, use AA, AB, AC, etc.
            first_letter_idx = div(i - 1, 26) + 1
            second_letter_idx = ((i - 1) % 26) + 1
            mapping[client] = string(alphabet[first_letter_idx]) * string(alphabet[second_letter_idx])
        end
    end
    return mapping
end

function scale_distribution!(distribution, demand, clients)
    # Divide distribution factor by the sum of demand for each client
    scaled_distribution = Dict()
    for client in clients
        scaled_distribution[client] = distribution[client]/sum(demand[!,client])
    end
    return scaled_distribution
end

function plot_results(
    allocations,
    systemData,
    allocation_costs,
    #bids,
    coalitionCost,
    clients,
    start_hour,
    sim_days,
    allocation_labels,
    WMAPE
)
    # Cutting data to the specified start hour and sim_days
    start_idx = findfirst(x -> x >= start_hour, systemData["price_prod_demand_df"][!,"HourUTC_datetime"])
    end_idx = start_idx + sim_days * 24 - 1
    dayData = deepcopy(systemData)
    dayData["price_prod_demand_df"] = systemData["price_prod_demand_df"][start_idx:end_idx, :]

    # Use clients directly (sorting should be done in plotting_main)
    plotKeys = clients
    
    # Create alphabetic mapping for display
    client_name_mapping = create_alphabetic_client_mapping(clients)
    plotKeysAlphabetic = [client_name_mapping[client] for client in plotKeys]

    skip_allocations = ["MCC", "nucleolus"]
    # Filter allocations to exclude skipped allocations
    allocations = filter(x -> x in allocations && !(x in skip_allocations), keys(allocation_costs))

    # Cost per MWh
    cost_MWh = Dict()
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            cost_MWh[alloc] = scale_distribution!(allocation_costs[alloc], dayData["price_prod_demand_df"], clients)
        end
    end
    yMax =maximum([maximum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
    #yMin = minimum([minimum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
    p_fees_MWh = plot(
        #title="Imbalance cost per MWh demand",
        xlabel="Client",
        ylabel="Imbalance cost [€/MWh]",
        xticks=(1:length(plotKeys), plotKeysAlphabetic),
        xrotation=45,
        #legend=:topright,
        #ylim = (0, yMax * 1.1),
        #titlefont=font(10)  # Reduce title font size
        tickfont=font(12),
        guidefont=font(14)
    )
    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [cost_MWh[alloc][k] for k in plotKeys]
            scatter!(p_fees_MWh, 1:length(plotKeys), -plotVals, label=label, color=color)
        end
    end
    display(p_fees_MWh)

    # Plot Cost per MWh compared to percentage of demand covered by PV production
    pv_coverage_ratio = Dict()
    for client in plotKeys
        total_demand = sum(dayData["price_prod_demand_df"][!, Symbol(client)])
        total_pv_for_client = sum(dayData["price_prod_demand_df"][!, "SolarMWh"]) * systemData["clientPVOwnership"][client]
        pv_coverage_ratio[client] = (total_pv_for_client / total_demand) * 100  # Convert to percentage
    end
 
    p_pv_coverage = plot(
        title="PV Coverage of Demand",
        xlabel="Client",
        ylabel="PV Coverage [%]",
        xticks=(1:length(plotKeys), plotKeysAlphabetic),
        xrotation=45,
        ylim = (0, 210),
        tickfont=font(12),
        guidefont=font(14)
    )
    bar!(p_pv_coverage, 1:length(plotKeys), [pv_coverage_ratio[client] for client in plotKeys], label="PV Coverage")
    display(p_pv_coverage)
    
    p_Cost_vs_pv = plot(
        title="Imbalance cost per MWh vs PV Coverage",
        xlabel="PV Coverage of Demand [%]",
        ylabel="Imbalance cost [€/MWh]",
        legend=:outertopright,
        ylim = (0, yMax * 1.1),
        tickfont=font(12),
        guidefont=font(14)
    )
    
    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plotKeys]
            y_vals = [cost_MWh[alloc][k] for k in plotKeys]
            scatter!(p_Cost_vs_pv, x_vals, y_vals, label=label, color=color, alpha=1)
        end
    end
    display(p_Cost_vs_pv)

    # Plot Cost per MWh vs WMAPE
    p_Cost_vs_wmape = plot(
        #title="Imbalance cost per MWh vs WMAPE",
        xlabel="WMAPE [%]",
        ylabel="Imbalance cost [€/MWh]",
        #legend=:outertopright,
        #ylim = (0, yMax * 1.1),
        tickfont=font(12),
        guidefont=font(14),
        size=(600, 300),
        top_margin=4Plots.mm,
        bottom_margin=4Plots.mm,
        left_margin=4Plots.mm
    )
    println(plotKeys)
    for alloc in allocations
        if alloc != "full_cost"
            continue
        end
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [WMAPE[k] for k in plotKeys]
            y_vals = -[cost_MWh[alloc][k] for k in plotKeys]
            scatter!(p_Cost_vs_wmape, x_vals, y_vals, label=label, color=color, alpha=1)
            
            # Add best fit line (linear regression)
            if length(x_vals) > 1
                # Calculate linear regression: y = mx + b (vectorized for speed)
                n = length(x_vals)
                x_mean = sum(x_vals) / n
                y_mean = sum(y_vals) / n
                
                # Vectorized calculation
                x_centered = x_vals .- x_mean
                y_centered = y_vals .- y_mean
                numerator = sum(x_centered .* y_centered)
                denominator = sum(x_centered .^ 2)
                
                if denominator != 0
                    m = numerator / denominator
                    b = y_mean - m * x_mean
                    
                    # Calculate R²
                    y_pred = m .* x_vals .+ b
                    ss_res = sum((y_vals .- y_pred) .^ 2)
                    ss_tot = sum(y_centered .^ 2)
                    r_squared = 1 - (ss_res / ss_tot)
                    
                    # Generate points for the line
                    x_range = range(minimum(x_vals), maximum(x_vals), length=100)
                    y_fit = m .* x_range .+ b
                    
                    plot!(p_Cost_vs_wmape, x_range, y_fit, 
                          label="Best Fit (R² = $(round(r_squared, digits=3)))", 
                          color= RGB(136/255, 216/255, 176/255), 
                          linestyle=:dash, 
                          linewidth=2)
                end
            end
        end
    end
    display(p_Cost_vs_wmape)

    # Total Cost
    p_fees_total = plot(title="Total imbalance cost per client", xlabel="Client", ylabel="€", xticks=(1:length(plotKeys), plotKeysAlphabetic), xrotation=45, legend=:topright, tickfont=font(12), guidefont=font(14))
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [allocation_costs[alloc][k] for k in plotKeys]
            scatter!(p_fees_total, 1:length(plotKeys), plotVals, label=label, color=color)
        end
    end
    display(p_fees_total)

    # Cost contribution vs individual Cost
    CostRatio = Dict{String, Dict{String, Float64}}()
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            CostRatio[alloc] = Dict{String, Float64}()
            for client in plotKeys
                CostRatio[alloc][client] = allocation_costs[alloc][client] / coalitionCost[[client]]
                # Convert to percentage
                CostRatio[alloc][client] = CostRatio[alloc][client] * 100
            end
        end
    end

    #min_val = minimum([cost_imbalance[alloc][k] for alloc in allocations if haskey(cost_imbalance, alloc) for k in plotKeys])
    #lower_ylim = min(0.0, min_val - 0.05)  # Add a small margin below min_val, but not above 0
    p_CostRatio = plot(
        #title="Imbalance cost contribution vs individual cost\n Noise Demand Forecast, Perfect PV Forecast",
        xlabel="Client",
        ylabel="Relative Cost [%]",
        xticks=(1:length(plotKeys), plotKeysAlphabetic),
        xrotation=45,
        markersize = 2,
        #ylim=(0, 105),
        #legend=:bottomleft,
        size = (320, 200),
        tickfont=font(6, "Times Roman"),
        guidefont=font(8, "Times Roman"),
        legendfont=font(6, "Times Roman")
    )
    marker_shapes = [:circle, :rect, :diamond, :utriangle, :dtriangle, :cross, :xcross, :star5]
    shape_idx = 1
    for alloc in allocations
        if haskey(CostRatio, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [CostRatio[alloc][k] for k in plotKeys]
            marker = marker_shapes[mod1(shape_idx, length(marker_shapes))]
            scatter!(p_CostRatio, 1:length(plotKeys), plotVals, label=label, color=color, markershape=marker)
            shape_idx += 1
        end
    end
    savefig(p_CostRatio, "p_CostRatio.svg")
    display(p_CostRatio)

    # Plot CostRatio vs PV Coverage
    p_Cost_ratio_vs_pv = plot(
        title="Imbalance Cost Ratio vs PV Coverage",
        xlabel="PV Coverage of Demand [%]",
        ylabel="%",
        legend=:outertopright,
        ylim = (0, 105),
        tickfont=font(12),
        guidefont=font(14)
    )
    
    for alloc in allocations
        if haskey(CostRatio, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plotKeys]
            y_vals = [CostRatio[alloc][k] for k in plotKeys]
            scatter!(p_Cost_ratio_vs_pv, x_vals, y_vals, label=label, color=color, alpha=1)
        end
    end
    display(p_Cost_ratio_vs_pv)

    # Plot aggregate demand, PV production, bids, and imbalance
    #p_aggregate = plot(title="Aggregate Demand, PV Production, Bids, and Imbalance", xlabel="Hour", ylabel="Value")
    #aggregate_demand = sum(dayData["price_prod_demand_df"][!, client] for client in clients_without_missing_data)
    #aggregate_pvProd = sum(dayData["price_prod_demand_df"][!, "SolarMWh"] .* systemData["clientPVOwnership"][client] for client in clients_without_missing_data)
    #combined_bids = bids[clients_without_missing_data]
    #combined_imbalance = combined_bids + aggregate_pvProd - aggregate_demand
    #n_hours = length(aggregate_demand)
    #plot!(p_aggregate, 1:n_hours, aggregate_demand, label="Aggregate Demand")
    #plot!(p_aggregate, 1:n_hours, aggregate_pvProd, label="Aggregate PV Production")
    #plot!(p_aggregate, 1:n_hours, combined_bids, label="Combined Bids")
    #plot!(p_aggregate, 1:n_hours, combined_imbalance, label="Combined Imbalance")
    #display(p_aggregate)

    


    # Plot total MWh demand per client
    total_MWh_demand = Dict(client => sum(dayData["price_prod_demand_df"][!, Symbol(client)]) for client in plotKeys)
    p_total_demand = plot(
        #title="Total MWh Demand per Client", 
        xlabel="Client", ylabel="Total Demand [MWh]", xticks=(1:length(plotKeys), plotKeysAlphabetic), xrotation=45, legend=:topright, tickfont=font(12), guidefont=font(14)
    )
    plotVals_total_demand = [total_MWh_demand[k] for k in plotKeys]
    bar!(p_total_demand, 1:length(plotKeys), plotVals_total_demand, label=false, color=:black)
    display(p_total_demand)
    
    # Socialised vs Individualised Plot
    # Check if we have both flat_rate and full_cost allocations
    if haskey(allocation_costs, "flat_rate") && haskey(allocation_costs, "full_cost")
        socialisedAllocation = "flat_rate"
        individualAllocation = "full_cost"
        individualizationSteps = 0:0.05:1
        
        # Create mixed allocation DataFrame
        mixedAllocationDF = DataFrame(step = collect(individualizationSteps))
        for client in clients
            flat = allocation_costs[socialisedAllocation][client]
            indiv = allocation_costs[individualAllocation][client]
            mixedAllocationDF[!, client] = (1 .- mixedAllocationDF.step) .* flat .+ mixedAllocationDF.step .* indiv
        end
        
        # Check stability (find where max excess becomes negative)
        negativeExcessStep = nothing
        # Create a full cost dictionary for stability checking
        
        for row in eachrow(mixedAllocationDF)
            stepAllocation = Dict(client => row[client] for client in clients)
            maxExcessStep = check_stability(stepAllocation, coalitionCost, clients)
            if maxExcessStep < 0
                negativeExcessStep = row[:step]
                break
            end
        end
        # Plot socialised vs individualised
        p_mixed = plot_socialised_vs_individualised(mixedAllocationDF, clients, dayData; negativeExcessStep=negativeExcessStep)
        display(p_mixed)
    end
end

function plot_cost_difference(allocation_costs, clients, systemData)
    # This function compares the cost of the most expensive allocation with the least expensive for each client
    # Flat_rate is excluded from this comparison
    filtered_allocations = filter(x -> x != "flat_rate", keys(allocation_costs))
    filtered_allocations = filter(x -> x != "MCC" , filtered_allocations)
    # Convert to vector for indexing
    filtered_allocations = collect(filtered_allocations)
    
    # Create alphabetic mapping for display
    client_name_mapping = create_alphabetic_client_mapping(clients)
    clientsAlphabetic = [client_name_mapping[client] for client in clients]
    
    # Calculate cost per MWh for each allocation
    cost_MWh = Dict()
    for alloc in filtered_allocations
        if haskey(allocation_costs, alloc)
            cost_MWh[alloc] = scale_distribution!(allocation_costs[alloc], systemData["price_prod_demand_df"], clients)
        end
    end
    
    # Calculate percentage increase and absolute difference for each client
    cost_percent_increase = Dict{String, Float64}()
    cost_absolute_difference = Dict{String, Float64}()
    for client in clients
        max_cost = maximum(cost_MWh[alloc][client] for alloc in filtered_allocations)
        min_cost = minimum(cost_MWh[alloc][client] for alloc in filtered_allocations)

        # Calculate percentage increase: ((max - min) / min) * 100
        cost_percent_increase[client] = ((max_cost - min_cost) / min_cost) * 100
        # Calculate absolute difference in €/MWh
        cost_absolute_difference[client] = max_cost - min_cost
        #println("Client: $client, Max Cost: $max_cost, Min Cost: $min_cost, Percentage Increase: $(cost_percent_increase[client]), Absolute Difference: $(cost_absolute_difference[client])")
    end

    # Create two separate plots
    p1 = bar(
        1:length(clients),
        [cost_percent_increase[client] for client in clients],
        title="Cost Increase: Percentage",
        xlabel="Client",
        ylabel="Percentage Increase [%]",
        xticks=(1:length(clients), clientsAlphabetic),
        xrotation=45,
        color=:blue,
        legend=:none,
        tickfont=font(12),
        guidefont=font(14)
    )
    display(p1)
    
    p2 = bar(
        1:length(clients),
        [cost_absolute_difference[client] for client in clients],
        title="Cost Increase: Absolute",
        xlabel="Client",
        ylabel="Cost Difference [€/MWh]",
        xticks=(1:length(clients), clientsAlphabetic),
        xrotation=45,
        color=:red,
        legend=:none,
        tickfont=font(12),
        guidefont=font(14)
    )
    display(p2)
    # Print a table with the most expensive and cheapest allocation for each client
    println("Client\tCheapest Allocation\tCheapest €/MWh\tMost Expensive Allocation\tMost Expensive €/MWh")
    for (i, client) in enumerate(clients)
        min_alloc = argmin([cost_MWh[alloc][client] for alloc in filtered_allocations])
        max_alloc = argmax([cost_MWh[alloc][client] for alloc in filtered_allocations])
        cheapest_alloc = filtered_allocations[min_alloc]
        most_expensive_alloc = filtered_allocations[max_alloc]
        cheapest_cost = cost_MWh[cheapest_alloc][client]
        most_expensive_cost = cost_MWh[most_expensive_alloc][client]
        println("$(clientsAlphabetic[i])\t$(cheapest_alloc)\t$(round(cheapest_cost, digits=2))\t$(most_expensive_alloc)\t$(round(most_expensive_cost, digits=2))")
    end
end

function plot_socialised_vs_individualised(
    mixedAllocationDF,
    clients,
    systemData;
    negativeExcessStep=nothing
)
    """
    Create a scatter plot showing cost per MWh vs individualization step for each client.
    
    Parameters:
    - mixedAllocationDF: DataFrame with columns 'step' and one column per client containing their costs
    - clients: Array of client identifiers
    - systemData: System data dictionary containing demand information
    - negativeExcessStep: Optional step value where max excess becomes negative (adds vertical line)
    
    Returns:
    - Plot object
    """
    
    # Calculate cost per MWh for each client
    totalDemandByClient = Dict(client => sum(systemData["price_prod_demand_df"][!, client]) for client in clients)
    mixedAllocationCostPerMWhDF = DataFrame(step = mixedAllocationDF.step)
    for client in clients
        denom = totalDemandByClient[client]
        if isnothing(denom) || denom == 0
            mixedAllocationCostPerMWhDF[!, client] = fill(missing, nrow(mixedAllocationDF))
        else
            mixedAllocationCostPerMWhDF[!, client] = mixedAllocationDF[!, client] ./ denom
        end
    end
    
    # Flip sign to convert from income to cost for plotting
    mixedAllocationCostPerMWhDF_plot = copy(mixedAllocationCostPerMWhDF)
    for client in clients
        mixedAllocationCostPerMWhDF_plot[!, client] = -mixedAllocationCostPerMWhDF[!, client]
    end
    
    p = plot(
        xlabel = "Individualisation Grade",
        ylabel = "Imbalance cost [€/MWh]",
        background_color = :white,
        foreground_color_subplot = :black,
        tickfont=font(6, "Times Roman"),
        guidefont=font(8, "Times Roman"),
        legendfont=font(6, "Times Roman"),
        size=(320, 160),
        #top_margin=4Plots.mm,
        #bottom_margin=4Plots.mm,
        #left_margin=4Plots.mm,
        legend = :topleft
    )
    
    # Create color gradient from low to high cost: LightGreen -> Sand -> Orange -> Red
    LightGreen = RGB(150/255, 206/255, 180/255)
    Sand = RGB(255/255, 238/255, 173/255)
    Orange = RGB(255/255, 204/255, 92/255)
    Red = RGB(255/255, 111/255, 105/255)
    Green = RGB(136/255, 216/255, 176/255)
    
    final_costs = [mixedAllocationCostPerMWhDF_plot[end, client] for client in clients]
    cost_order = sortperm(final_costs)  # Low to high
    
    # Create gradient through all four colors
    n_clients = length(clients)
    if n_clients == 1
        palette_colors = [LightGreen]
    elseif n_clients == 2
        palette_colors = [LightGreen, Red]
    elseif n_clients == 3
        palette_colors = [LightGreen, Orange, Red]
    else
        # Interpolate through all four colors
        n_per_segment = div(n_clients - 1, 3)
        remainder = (n_clients - 1) % 3
        
        # Distribute remainder across segments
        n1 = n_per_segment + (remainder >= 1 ? 1 : 0) + 1
        n2 = n_per_segment + (remainder >= 2 ? 1 : 0) + 1
        n3 = n_per_segment + (remainder >= 3 ? 1 : 0) + 1
        
        gradient1 = range(LightGreen, stop=Sand, length=n1)
        gradient2 = range(Sand, stop=Orange, length=n2)
        gradient3 = range(Orange, stop=Red, length=n3)
        
        # Combine gradients, removing duplicate intermediate points
        color_gradient = vcat(collect(gradient1)[1:end-1], collect(gradient2)[1:end-1], collect(gradient3))
    end
    
    palette_colors = [color_gradient[findfirst(==(i), cost_order)] for i in 1:length(clients)]
    
    for (i, client) in enumerate(clients)
        plot!(p,
            mixedAllocationCostPerMWhDF_plot.step,
            mixedAllocationCostPerMWhDF_plot[!, client],
            label = (i == 1 ? "Client Cost" : ""),
            color = palette_colors[i],
            lw = 2,
            xguidefont = font(8, "Times Roman"),
            yguidefont = font(8, "Times Roman"),
            xtickfont = font(6, "Times Roman"),
            ytickfont = font(6, "Times Roman"),
        )
    end
    
    # Add vertical line where max excess becomes negative
    if !isnothing(negativeExcessStep)
        vline!(p, [negativeExcessStep], 
               color = Green, 
               linestyle = :dash, 
               linewidth = 3,
               label = "Line of Stability")
    end
    
    return p
end
