using Plots, Serialization, CSV, DataFrames, StatsPlots

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
    allocation_labels;
    cvar = false
)
    # Cutting data to the specified start hour and sim_days
    start_idx = findfirst(x -> x >= start_hour, systemData["price_prod_demand_df"][!,"HourUTC_datetime"])
    end_idx = start_idx + sim_days * 24*4 - 1
    dayData = deepcopy(systemData)
    dayData["price_prod_demand_df"] = systemData["price_prod_demand_df"][start_idx:end_idx, :]

    # Use clients directly (sorting should be done in plotting_main)
    plotKeys = clients

    skip_allocations = ["VCG", "nucleolus"]
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
    if cvar == false
        p_fees_MWh = plot(
            title="Imbalance cost per MWh demand\n Noise Demand Forecast, Perfect PV Forecast",
            #title="Imbalance cost per MWh demand",
            xlabel="Client",
            ylabel="€/MWh",
            xticks=(1:length(plotKeys), plotKeys),
            xrotation=45,
            legend=:topright,
            #ylim = (0, yMax * 1.1),
            #titlefont=font(10)  # Reduce title font size
        )
    else
        ymin = minimum([minimum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
        p_fees_MWh = plot(
            title="CVaR contribution per MWh demand",
            xlabel="Client",
            ylabel="€/MWh",
            xticks=(1:length(plotKeys), plotKeys),
            xrotation=45,
            legend=:topleft,
            ylim = (ymin-0.01, yMax * 1.1),
            titlefont=font(10)  # Reduce title font size
        )
    end
    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [cost_MWh[alloc][k] for k in plotKeys]
            scatter!(p_fees_MWh, 1:length(plotKeys), plotVals, label=label, color=color)
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
        xticks=(1:length(plotKeys), plotKeys),
        xrotation=45,
        ylim = (0, 210)
    )
    bar!(p_pv_coverage, 1:length(plotKeys), [pv_coverage_ratio[client] for client in plotKeys], label="PV Coverage")
    display(p_pv_coverage)
    
    if cvar == false
        p_Cost_vs_pv = plot(
            title="Imbalance cost per MWh vs PV Coverage",
            xlabel="PV Coverage of Demand [%]",
            ylabel="€/MWh",
            legend=:outertopright,
            ylim = (0, yMax * 1.1),
        )
    else
        ymin = minimum([minimum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
        p_Cost_vs_pv = plot(
            title="CVaR contribution per MWh vs PV Coverage",
            xlabel="PV Coverage of Demand [%]",
            ylabel="€/MWh",
            legend=:outertopright,
            ylim = (ymin-0.05, yMax * 1.1),
        )
    end
    
    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plotKeys]
            y_vals = [cost_MWh[alloc][k] for k in plotKeys]
            scatter!(p_Cost_vs_pv, x_vals, y_vals, label=label, color=color, alpha=0.7)
        end
    end
    display(p_Cost_vs_pv)

    # Total Cost
    if cvar == false
        p_fees_total = plot(title="Total imbalance cost per client", xlabel="Client", ylabel="€", xticks=(1:length(plotKeys), plotKeys), xrotation=45, legend=:topright)
    else
        ymin = minimum([minimum(allocation_costs[alloc][k] for k in plotKeys) for alloc in allocations if haskey(allocation_costs, alloc)])
        p_fees_total = plot(title="CVaR contribution total per client", xlabel="Client", ylabel="€", xticks=(1:length(plotKeys), plotKeys), xrotation=45, legend=:topright, ylim = (ymin-0.05, maximum([maximum(allocation_costs[alloc][k] for k in plotKeys) for alloc in allocations if haskey(allocation_costs, alloc)]) * 1.1))
    end
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
    if cvar == false
        p_CostRatio = plot(
            title="Imbalance cost contribution vs individual cost\n Noise Demand Forecast, Perfect PV Forecast",
            xlabel="Client",
            ylabel="Relative cost [%]",
            xticks=(1:length(plotKeys), plotKeys),
            xrotation=45,
            #ylim=(0, 105),
            #legend=:bottomleft
        )
    else
        ymin = minimum([minimum(CostRatio[alloc][k] for k in plotKeys) for alloc in allocations if haskey(CostRatio, alloc)])
        p_CostRatio = plot(
            title="CVaR contribution vs individual CVaR",
            xlabel="Client",
            ylabel="Relative CVaR [%]",
            xticks=(1:length(plotKeys), plotKeys),
            xrotation=45,
            ylim=(ymin-0.05, 105),
            legend=:bottomleft
        )
    end
    for alloc in allocations
        if haskey(CostRatio, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [CostRatio[alloc][k] for k in plotKeys]
            scatter!(p_CostRatio, 1:length(plotKeys), plotVals, label=label, color=color)
        end
    end
    display(p_CostRatio)

    # Plot CostRatio vs PV Coverage
    if cvar == false
        p_Cost_ratio_vs_pv = plot(
            title="Imbalance Cost Ratio vs PV Coverage",
            xlabel="PV Coverage of Demand [%]",
            ylabel="%",
            legend=:outertopright,
            ylim = (0, 105)
        )
    else
        ymin = minimum([minimum(CostRatio[alloc][k] for k in plotKeys) for alloc in allocations if haskey(CostRatio, alloc)])
        p_Cost_ratio_vs_pv = plot(
            title="CVaR Contribution Ratio vs PV Coverage",
            xlabel="PV Coverage of Demand [%]",
            ylabel="%",
            legend=:outertopright,
            ylim = (ymin-0.05, 105)
        )
    end
    
    for alloc in allocations
        if haskey(CostRatio, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plotKeys]
            y_vals = [CostRatio[alloc][k] for k in plotKeys]
            scatter!(p_Cost_ratio_vs_pv, x_vals, y_vals, label=label, color=color, alpha=0.7)
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
    p_total_demand = plot(title="Total MWh Demand per Client", xlabel="Client", ylabel="Total Demand [MWh]", xticks=(1:length(plotKeys), plotKeys), xrotation=45, legend=:topright)
    plotVals_total_demand = [total_MWh_demand[k] for k in plotKeys]
    bar!(p_total_demand, 1:length(plotKeys), plotVals_total_demand, label=false)
    display(p_total_demand)
end

function plot_variance(
    allocations,
    daily_cost,
    singletonCosts,
    plot_client,
    sim_days,
    allocation_labels;
    outliers = true
)
    # Allocations that should not be plotted
    skip_allocations = ["VCG", "nucleolus", "flat_rate", "shapley"]
    
    # Filter allocations for x-axis labels
    filtered_allocations = [a for a in allocations if haskey(allocation_labels, a) && !(a in skip_allocations)]
    
    p_variance = plot(
        title="Daily relative costs $plot_client",
        xlabel="Allocation",
        ylabel="Relative costs [%]",
        xticks=(1:length(filtered_allocations), [allocation_labels[a][1] for a in filtered_allocations]),
        legend = :bottomright,
        xrotation=30
    )
    
    plot_index = 1
    weighted_mean_labeled = false
    median_labeled = false
    for alloc in filtered_allocations
        label, color = allocation_labels[alloc]

        plotVals = daily_cost[(plot_client, alloc)]./singletonCosts[plot_client] * 100  # Convert to percentage
        boxplot!(fill(plot_index, sim_days), plotVals; color=color, markerstrokecolor=:black, label=false, outliers=outliers)
        mean_val_weighted = sum(daily_cost[(plot_client, alloc)])/sum(singletonCosts[plot_client]) * 100  # Convert to percentage
        
        # Add median to legend (only once)
        if !median_labeled
            # Create a dummy line to represent the median in the legend
            plot!(Float64[], Float64[], color=:black, linewidth=2, label="Median")
            median_labeled = true
        end
        
        # Add a blue line for the weighted mean
        weighted_mean_label = weighted_mean_labeled ? false : "Weighted Mean"
        plot!([plot_index-0.4, plot_index+0.4], [mean_val_weighted, mean_val_weighted], color=:blue, linewidth=2, label=weighted_mean_label)
        weighted_mean_labeled = true
        plot_index += 1
    end
    display(p_variance)
end

function plot_cost_difference(allocation_costs, clients, systemData)
    # This function compares the cost of the most expensive allocation with the least expensive for each client
    # Flat_rate is excluded from this comparison
    filtered_allocations = filter(x -> x != "flat_rate", keys(allocation_costs))
    filtered_allocations = filter(x -> x != "VCG" , filtered_allocations)
    # Convert to vector for indexing
    filtered_allocations = collect(filtered_allocations)
    
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
        xticks=(1:length(clients), clients),
        xrotation=45,
        color=:blue,
        legend=:none
    )
    display(p1)
    
    p2 = bar(
        1:length(clients),
        [cost_absolute_difference[client] for client in clients],
        title="Cost Increase: Absolute",
        xlabel="Client",
        ylabel="Cost Difference [€/MWh]",
        xticks=(1:length(clients), clients),
        xrotation=45,
        color=:red,
        legend=:none
    )
    display(p2)
    # Print a table with the most expensive and cheapest allocation for each client
    println("Client\tCheapest Allocation\tCheapest €/MWh\tMost Expensive Allocation\tMost Expensive €/MWh")
    for client in clients
        min_alloc = argmin([cost_MWh[alloc][client] for alloc in filtered_allocations])
        max_alloc = argmax([cost_MWh[alloc][client] for alloc in filtered_allocations])
        cheapest_alloc = filtered_allocations[min_alloc]
        most_expensive_alloc = filtered_allocations[max_alloc]
        cheapest_cost = cost_MWh[cheapest_alloc][client]
        most_expensive_cost = cost_MWh[most_expensive_alloc][client]
        println("$(client)\t$(cheapest_alloc)\t$(round(cheapest_cost, digits=2))\t$(most_expensive_alloc)\t$(round(most_expensive_cost, digits=2))")
    end
end
