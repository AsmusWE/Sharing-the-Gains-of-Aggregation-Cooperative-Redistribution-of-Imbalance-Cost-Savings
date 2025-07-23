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
    sim_days
)
    # Cutting data to the specified start hour and sim_days
    start_idx = findfirst(x -> x >= start_hour, systemData["price_prod_demand_df"][!,"HourUTC_datetime"])
    end_idx = start_idx + sim_days * 24*4 - 1
    dayData = deepcopy(systemData)
    dayData["price_prod_demand_df"] = systemData["price_prod_demand_df"][start_idx:end_idx, :]

    # Rank clients by average demand
    avg_demands = Dict(client => sum(dayData["price_prod_demand_df"][!, Symbol(client)]) / length(dayData["price_prod_demand_df"][!, Symbol(client)]) for client in clients)
    sorted_clients = sort(collect(avg_demands), by = x -> -x[2])
    plotKeys = [client for (client, _) in sorted_clients]

    # Prepare color and label mapping for allocations
    allocation_labels = Dict(
        "shapley" => ("Shapley", :red),
        "VCG" => ("VCG", :yellow),
        "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
        "gately" => ("Gately Point", :grey),
        #"gately_daily" => ("Gately Daily", :black),
        "gately_interval" => ("Gately 15Min interval", :lightgrey),
        "full_cost" => ("Full Cost", :pink),
        "reduced_cost" => ("Reduced Cost", :lightblue),
        "nucleolus" => ("Nucleolus", :green),
        "equal_share" => ("Equal Share", :purple),
        #"cost_based" => ("Cost Based", :cyan),
        "flat_rate" => ("Flat Rate", :cyan)
    )

    # CVaR per MWh
    cost_MWh = Dict()
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            cost_MWh[alloc] = scale_distribution!(allocation_costs[alloc], dayData["price_prod_demand_df"], clients)
        end
    end
    #yMax =maximum([maximum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
    #yMin = minimum([minimum(cost_MWh[alloc][k] for k in plotKeys) for alloc in allocations if haskey(cost_MWh, alloc)])
    p_fees_MWh = plot(
        title="Imbalance cost per MWh demand",
        xlabel="Client",
        ylabel="€/MWh",
        xticks=(1:length(plotKeys), plotKeys),
        xrotation=45,
        legend=:outertopright,
    ) #, ylim = (0, yMax * 1.1)
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
        #ylim = (0, yMax * 1.1),
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
    p_fees_total = plot(title="Total imbalance cost per client", xlabel="Client", ylabel="€", xticks=(1:length(plotKeys), plotKeys), xrotation=45, legend=:outertopright)
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
        ylabel="%",
        xticks=(1:length(plotKeys), plotKeys),
        xrotation=45,
        ylim=(0, 100),
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
        ylim = (0, 100)
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
    p_total_demand = plot(title="Total MWh Demand per Client", xlabel="Client", ylabel="Total MWh Demand", xticks=(1:length(plotKeys), plotKeys), xrotation=45, legend=:outertopright)
    plotVals_total_demand = [total_MWh_demand[k] for k in plotKeys]
    bar!(p_total_demand, 1:length(plotKeys), plotVals_total_demand, label="Total MWh Demand")
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
    allocation_labels = Dict(
        "shapley" => ("Shapley", :red),
        "VCG" => ("VCG", :yellow),
        "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
        "gately_daily" => ("Gately Daily", :grey),
        #"gately_daily" => ("Gately Daily", :black),
        "gately_interval" => ("Gately 15Min interval", :lightgrey),
        "full_cost" => ("Full Cost", :pink),
        "reduced_cost" => ("Reduced Cost", :lightblue),
        "nucleolus" => ("Nucleolus", :green)
    )
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
    allocation_costs,
    daily_cost_MWh_imbalance,
    imbalances,
    plot_client,
    sim_days;
    outliers = true
)
    # Prepare color and label mapping for allocations
    allocation_labels = Dict(
        "shapley" => ("Shapley", :red),
        "VCG" => ("VCG", :yellow),
        "VCG_budget_balanced" => ("VCG Budget Balanced", :orange),
        "gately" => ("Gately Daily", :grey),
        #"gately_daily" => ("Gately Daily", :black),
        "gately_interval" => ("Gately 15Min interval", :lightgrey),
        "full_cost" => ("Full Cost", :pink),
        "reduced_cost" => ("Reduced Cost", :lightblue),
        "nucleolus" => ("Nucleolus", :green),
        "equal_share" => ("Equal Share", :purple),
        #"cost_based" => ("Cost Based", :cyan),
        "flat_rate" => ("Flat Rate", :cyan)
    )

    p_variance = plot(
        title="Imbalance compared to no cooperation, client $plot_client",
        xlabel="Allocation",
        ylabel="Imbalance compared to no cooperation",
        xticks=(1:length(allocations), [allocation_labels[a][1] for a in allocations]),
        legend = :none,
        xrotation=45
    )
    
    for (i, alloc) in enumerate(allocations)
        if haskey(allocation_labels, alloc)
            label, color = allocation_labels[alloc]
            plotVals = [daily_cost_MWh_imbalance[(plot_client, alloc, day)] for day in 1:sim_days]
            boxplot!(fill(i, sim_days), plotVals; color=color, markerstrokecolor=:black, label=label, outliers=outliers)
            mean_val_unweighted = sum(plotVals) / length(plotVals)
            mean_val_weighted = allocation_costs[alloc][plot_client]/imbalances[[plot_client]]
            #annotate!(i, mean_val_unweighted, text(string(round(mean_val_unweighted, digits=4)), :black, :center, 8))
            # Add a red line for the weighted mean
            plot!([i-0.4, i+0.4], [mean_val_weighted, mean_val_weighted], color=:blue, linewidth=2, label=false)
        end
    end
    display(p_variance)
end
