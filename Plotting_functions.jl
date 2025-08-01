using Plots, Serialization, CSV, DataFrames

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
    coalitionCVaR,
    clients,
    start_hour,
    sim_days,
    allocation_labels
)
    # Cutting data to the specified start hour and sim_days
    start_idx = findfirst(x -> x >= start_hour, systemData["price_prod_demand_df"][!,"HourUTC_datetime"])
    end_idx = start_idx + sim_days * 24*4 - 1
    dayData = deepcopy(systemData)
    dayData["price_prod_demand_df"] = systemData["price_prod_demand_df"][start_idx:end_idx, :]

    # Use clients directly (sorting should be done in plotting_main)
    plotKeys = clients

    skip_allocations = ["VCG", "VCG_budget_balanced", "nucleolus"]
    # Filter allocations to exclude skipped allocations
    allocations = filter(x -> x in allocations && !(x in skip_allocations), keys(allocation_costs))

    # CVaR per MWh
    cost_MWh = Dict()
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            cost_MWh[alloc] = scale_distribution!(allocation_costs[alloc], dayData["price_prod_demand_df"], clients)
        end
    end
    yMax =maximum([maximum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
    #yMin = minimum([minimum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
    p_fees_MWh = plot(
        title="Imbalance cost per MWh demand, noise forecast, perfect PV forecast",
        xlabel="Client",
        ylabel="€/MWh",
        xticks=(1:length(plotKeys), plotKeys),
        xrotation=45,
        legend=:topright,
        ylim = (0, yMax * 1.1),
        titlefont=font(10)  # Reduce title font size
    )
    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [cost_MWh[alloc][k] for k in plotKeys]
            scatter!(p_fees_MWh, 1:length(plotKeys), plotVals, label=label, color=color)
        end
    end
    display(p_fees_MWh)

    # Plot CVaR per MWh compared to percentage of demand covered by PV production
    pv_coverage_ratio = Dict()
    for client in plotKeys
        total_demand = sum(dayData["price_prod_demand_df"][!, Symbol(client)])
        total_pv_for_client = sum(dayData["price_prod_demand_df"][!, "SolarMWh"]) * systemData["clientPVOwnership"][client]
        pv_coverage_ratio[client] = (total_pv_for_client / total_demand) * 100  # Convert to percentage
    end
    
    p_cvar_vs_pv = plot(
        title="Imbalance cost per MWh vs PV Coverage",
        xlabel="PV Coverage of Demand [%]",
        ylabel="€/MWh",
        legend=:outertopright,
        ylim = (0, yMax * 1.1),
    )
    
    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plotKeys]
            y_vals = [cost_MWh[alloc][k] for k in plotKeys]
            scatter!(p_cvar_vs_pv, x_vals, y_vals, label=label, color=color, alpha=0.7)
        end
    end
    display(p_cvar_vs_pv)

    # Total CVaR
    p_fees_total = plot(title="Total imbalance cost per client", xlabel="Client", ylabel="€", xticks=(1:length(plotKeys), plotKeys), xrotation=45, legend=:topright)
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [allocation_costs[alloc][k] for k in plotKeys]
            scatter!(p_fees_total, 1:length(plotKeys), plotVals, label=label, color=color)
        end
    end
    display(p_fees_total)

    # CVaR contribution vs individual CVaR
    CVaRRatio = Dict{String, Dict{String, Float64}}()
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            CVaRRatio[alloc] = Dict{String, Float64}()
            for client in plotKeys
                CVaRRatio[alloc][client] = allocation_costs[alloc][client] / coalitionCVaR[[client]]
                # Convert to percentage
                CVaRRatio[alloc][client] = CVaRRatio[alloc][client] * 100
            end
        end
    end

    #min_val = minimum([cost_imbalance[alloc][k] for alloc in allocations if haskey(cost_imbalance, alloc) for k in plotKeys])
    #lower_ylim = min(0.0, min_val - 0.05)  # Add a small margin below min_val, but not above 0
    p_CVaRRatio = plot(
        title="Imbalance cost contribution vs individual cost",
        xlabel="Client",
        ylabel="Relative cost [%]",
        xticks=(1:length(plotKeys), plotKeys),
        xrotation=45,
        ylim=(0, 105),
        legend=:outertopright
    )
    for alloc in allocations
        if haskey(CVaRRatio, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [CVaRRatio[alloc][k] for k in plotKeys]
            scatter!(p_CVaRRatio, 1:length(plotKeys), plotVals, label=label, color=color)
        end
    end
    display(p_CVaRRatio)

    # Plot CVaRRatio vs PV Coverage
    p_cvar_ratio_vs_pv = plot(
        title="Contribution/individual Ratio vs PV Coverage",
        xlabel="PV Coverage of Demand [%]",
        ylabel="%",
        legend=:outertopright,
        ylim = (0, 105)
    )
    
    for alloc in allocations
        if haskey(CVaRRatio, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plotKeys]
            y_vals = [CVaRRatio[alloc][k] for k in plotKeys]
            scatter!(p_cvar_ratio_vs_pv, x_vals, y_vals, label=label, color=color, alpha=0.7)
        end
    end
    display(p_cvar_ratio_vs_pv)

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

function save_rel_imbal(all_noise, all_scen, nuc_noise, nuc_scen)
    plotdata_list = [all_noise, all_scen, nuc_noise, nuc_scen]
    plot_titles = [
        "All, Noise",
        "All, Scenario",
        "Nucleolus, Noise",
        "Nucleolus, Scenario"
    ]
    all_rows = DataFrame()
    for idx in 1:4
        pd = plotdata_list[idx]
        allocations = pd.allocations
        allocation_costs = pd.allocation_costs
        imbalances = pd.imbalances
        clients = pd.clients
        plotKeys = clients
        scenario = plot_titles[idx]
        # Calculate grand coalition and average relative imbalance
        grand_coalition_imbalance = imbalances[clients]
        individual_imbalance_sum = sum(imbalances[[client]] for client in clients)
        average_relative_imbalance = grand_coalition_imbalance / individual_imbalance_sum
        for alloc in allocations
            if haskey(allocation_costs, alloc)
                for client in plotKeys
                    value = allocation_costs[alloc][client] / imbalances[[client]]
                    push!(all_rows, (
                        Scenario = scenario,
                        Allocation = alloc,
                        Client = client,
                        Value = value,
                        AverageRelativeImbalance = average_relative_imbalance,
                    ))
                end
            end
        end
    end
    CSV.write("Results/relative_imbalance_data.csv", all_rows)
    return all_rows
end

function save_variance_data(
    allocations,
    allocation_costs,
    daily_cost_MWh_imbalance,
    imbalances,
    clients,
    sim_days;
    scenario_name = ""
)
    rows = DataFrame()
    for alloc in allocations
        for client in clients
            for day in 1:sim_days
                value = daily_cost_MWh_imbalance[(client, alloc, day)]
                mean_val_weighted = allocation_costs[alloc][client] / imbalances[[client]]
                push!(rows, (
                    Scenario = scenario_name,
                    Allocation = alloc,
                    Client = client,
                    Day = day,
                    Value = value,
                    WeightedMean = mean_val_weighted
                ))
            end
        end
    end
    CSV.write("Results/variance_data.csv", rows)
    return rows
end

function plot_variance(
    allocations,
    daily_cost,
    plot_client,
    sim_days,
    allocation_labels;
    outliers = true
)
    # Allocations that should not be plotted
    skip_allocations = ["gately", "VCG", "VCG_budget_balanced", "nucleolus", "flat_rate"]
    
    # Filter allocations for x-axis labels
    filtered_allocations = [a for a in allocations if haskey(allocation_labels, a) && !(a in skip_allocations)]
    
    p_variance = plot(
        title="Imbalance cost per day, client $plot_client",
        xlabel="Allocation",
        ylabel="Imbalance cost per day [€/day]",
        xticks=(1:length(filtered_allocations), [allocation_labels[a][1] for a in filtered_allocations]),
        legend = :none,
        xrotation=0
    )
    
    plot_index = 1
    for alloc in filtered_allocations
        label, color = allocation_labels[alloc]

        plotVals = daily_cost[(plot_client, alloc)]./imbalances[[plot_client]]
        boxplot!(fill(plot_index, sim_days), plotVals; color=color, markerstrokecolor=:black, label=label, outliers=outliers)
        #mean_val_unweighted = sum(plotVals) / length(plotVals)
        #mean_val_weighted = allocation_costs[alloc][plot_client]/imbalances[[plot_client]]
        #annotate!(plot_index, mean_val_unweighted, text(string(round(mean_val_unweighted, digits=4)), :black, :center, 8))
        # Add a blue line for the weighted mean
        #plot!([plot_index-0.4, plot_index+0.4], [mean_val_weighted, mean_val_weighted], color=:blue, linewidth=2, label=false)
        plot_index += 1
    end
    display(p_variance)
end

function plot_cost_difference(allocation_costs, clients, systemData)
    # This function compares the cost of the most expensive allocation with the least expensive for each client
    # Flat_rate is excluded from this comparison
    filtered_allocations = filter(x -> x != "flat_rate", keys(allocation_costs))
    filtered_allocations = filter(x -> x != "VCG" && x != "VCG_budget_balanced", filtered_allocations)
    
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
end
