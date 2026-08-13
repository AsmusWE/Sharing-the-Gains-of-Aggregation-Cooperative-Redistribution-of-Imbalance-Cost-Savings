using Plots, Serialization, CSV, DataFrames
include("Game_theoretic_functions.jl")

# Shared color palette for cost-gradient plots (low cost -> high cost), also referenced
# from scripts/Plotting_main.jl and scripts/FigureScripts/*.jl instead of each redeclaring
# their own copy.
const PALETTE_LIGHT_GREEN = RGB(150/255, 206/255, 180/255)
const PALETTE_SAND        = RGB(255/255, 238/255, 173/255)
const PALETTE_ORANGE      = RGB(255/255, 204/255, 92/255)
const PALETTE_RED         = RGB(255/255, 111/255, 105/255)
const PALETTE_GREEN       = RGB(136/255, 216/255, 176/255)

# Shared text/size style for small paper-sized figures, also referenced from
# scripts/FigureScripts/Gains_Of_Aggregation.jl and scripts/FigureScripts/PVCoverage.jl
# instead of each redeclaring their own copy.
const SMALL_FIGURE_STYLE = (
    fontfamily = "Times Roman",
    tickfont = font(6, "Times Roman"),
    guidefont = font(8, "Times Roman"),
    size = (320, 120),
)

function sort_clients_by_demand(system_data, clients)
    # Sort clients by total demand, highest to lowest
    total_demands = Dict(client => sum(system_data["price_prod_demand_df"][!, Symbol(client)]) for client in clients)
    sorted_pairs = sort(collect(total_demands), by = x -> -x[2])
    return [client for (client, _) in sorted_pairs]
end

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

function scale_distribution(distribution, demand, clients)
    # Divide distribution factor by the sum of demand for each client
    scaled_distribution = Dict()
    for client in clients
        scaled_distribution[client] = distribution[client]/sum(demand[!,client])
    end
    return scaled_distribution
end

function plot_results(
    allocations,
    system_data,
    allocation_costs,
    #bids,
    coalition_costs,
    clients,
    start_hour,
    sim_days,
    allocation_labels,
    wmape
)
    # Cutting data to the specified start hour and sim_days
    start_idx = findfirst(x -> x >= start_hour, system_data["price_prod_demand_df"][!,"HourUTC_datetime"])
    end_idx = start_idx + sim_days * 24 - 1
    day_data = deepcopy(system_data)
    day_data["price_prod_demand_df"] = system_data["price_prod_demand_df"][start_idx:end_idx, :]

    # Use clients directly (sorting should be done in plotting_main)
    plot_keys = clients

    # Create alphabetic mapping for display
    client_name_mapping = create_alphabetic_client_mapping(clients)
    plot_keys_alphabetic = [client_name_mapping[client] for client in plot_keys]

    skip_allocations = ["MCC", "VCG", "nucleolus"]
    # Filter allocations to exclude skipped allocations
    allocations = filter(x -> x in allocations && !(x in skip_allocations), keys(allocation_costs))

    # Cost per MWh
    cost_MWh = Dict()
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            cost_MWh[alloc] = scale_distribution(allocation_costs[alloc], day_data["price_prod_demand_df"], clients)
        end
    end
    y_max = maximum([maximum(cost_MWh[alloc][k] for k in plot_keys) for alloc in allocations if haskey(cost_MWh, alloc)])
    p_fees_MWh = plot(
        #title="Imbalance cost per MWh demand",
        xlabel="Client",
        ylabel="Imbalance cost [€/MWh]",
        xticks=(1:length(plot_keys), plot_keys_alphabetic),
        xrotation=45,
        #legend=:topright,
        #ylim = (0, y_max * 1.1),
        #titlefont=font(10)  # Reduce title font size
        tickfont=font(12),
        guidefont=font(14)
    )
    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            plot_vals = [cost_MWh[alloc][k] for k in plot_keys]
            scatter!(p_fees_MWh, 1:length(plot_keys), -plot_vals, label=label, color=color)
        end
    end
    display(p_fees_MWh)

    # Plot Cost per MWh compared to percentage of demand covered by PV production
    pv_coverage_ratio = Dict()
    for client in plot_keys
        total_demand = sum(day_data["price_prod_demand_df"][!, Symbol(client)])
        total_pv_for_client = sum(day_data["price_prod_demand_df"][!, "SolarMWh"]) * system_data["client_pv_ownership"][client]
        pv_coverage_ratio[client] = (total_pv_for_client / total_demand) * 100  # Convert to percentage
    end

    p_pv_coverage = plot(
        title="PV Coverage of Demand",
        xlabel="Client",
        ylabel="PV Coverage [%]",
        xticks=(1:length(plot_keys), plot_keys_alphabetic),
        xrotation=45,
        ylim = (0, 210),
        tickfont=font(12),
        guidefont=font(14)
    )
    bar!(p_pv_coverage, 1:length(plot_keys), [pv_coverage_ratio[client] for client in plot_keys], label="PV Coverage")
    display(p_pv_coverage)

    p_cost_vs_pv = plot(
        title="Imbalance cost per MWh vs PV Coverage",
        xlabel="PV Coverage of Demand [%]",
        ylabel="Imbalance cost [€/MWh]",
        legend=:outertopright,
        ylim = (0, y_max * 1.1),
        tickfont=font(12),
        guidefont=font(14)
    )

    for alloc in allocations
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plot_keys]
            y_vals = [cost_MWh[alloc][k] for k in plot_keys]
            scatter!(p_cost_vs_pv, x_vals, y_vals, label=label, color=color, alpha=1)
        end
    end
    display(p_cost_vs_pv)

    # Plot Cost per MWh vs WMAPE
    p_cost_vs_wmape = plot(
        #title="Imbalance cost per MWh vs WMAPE",
        xlabel="WMAPE [%]",
        ylabel="Imbalance cost [€/MWh]",
        #legend=:outertopright,
        #ylim = (0, y_max * 1.1),
        tickfont=font(12),
        guidefont=font(14),
        size=(600, 300),
        top_margin=4Plots.mm,
        bottom_margin=4Plots.mm,
        left_margin=4Plots.mm
    )
    println(plot_keys)
    for alloc in allocations
        if alloc != "full_cost"
            continue
        end
        if haskey(cost_MWh, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [wmape[k] for k in plot_keys]
            y_vals = -[cost_MWh[alloc][k] for k in plot_keys]
            scatter!(p_cost_vs_wmape, x_vals, y_vals, label=label, color=color, alpha=1)

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

                    plot!(p_cost_vs_wmape, x_range, y_fit,
                          label="Best Fit (R² = $(round(r_squared, digits=3)))",
                          color= PALETTE_GREEN,
                          linestyle=:dash,
                          linewidth=2)
                end
            end
        end
    end
    display(p_cost_vs_wmape)

    # Total Cost
    p_fees_total = plot(title="Total imbalance cost per client", xlabel="Client", ylabel="€", xticks=(1:length(plot_keys), plot_keys_alphabetic), xrotation=45, legend=:topright, tickfont=font(12), guidefont=font(14))
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            label, color = allocation_labels[alloc]
            plot_vals = [allocation_costs[alloc][k] for k in plot_keys]
            scatter!(p_fees_total, 1:length(plot_keys), plot_vals, label=label, color=color)
        end
    end
    display(p_fees_total)

    # Cost contribution vs individual Cost
    cost_ratio = Dict{String, Dict{String, Float64}}()
    for alloc in allocations
        if haskey(allocation_costs, alloc)
            cost_ratio[alloc] = Dict{String, Float64}()
            for client in plot_keys
                cost_ratio[alloc][client] = allocation_costs[alloc][client] / coalition_costs[[client]]
                # Convert to percentage
                cost_ratio[alloc][client] = cost_ratio[alloc][client] * 100
            end
        end
    end

    p_cost_ratio = plot(
        #title="Imbalance cost contribution vs individual cost\n Noise Demand Forecast, Perfect PV Forecast",
        xlabel="Client",
        ylabel="Relative Cost [%]",
        xticks=(1:length(plot_keys), plot_keys_alphabetic),
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
        if haskey(cost_ratio, alloc)
            label, color = allocation_labels[alloc]
            plot_vals = [cost_ratio[alloc][k] for k in plot_keys]
            marker = marker_shapes[mod1(shape_idx, length(marker_shapes))]
            scatter!(p_cost_ratio, 1:length(plot_keys), plot_vals, label=label, color=color, markershape=marker)
            shape_idx += 1
        end
    end
    savefig(p_cost_ratio, "p_cost_ratio.svg")
    display(p_cost_ratio)

    # Plot cost_ratio vs PV Coverage
    p_cost_ratio_vs_pv = plot(
        title="Imbalance Cost Ratio vs PV Coverage",
        xlabel="PV Coverage of Demand [%]",
        ylabel="%",
        legend=:outertopright,
        ylim = (0, 105),
        tickfont=font(12),
        guidefont=font(14)
    )

    for alloc in allocations
        if haskey(cost_ratio, alloc)
            label, color = allocation_labels[alloc]
            x_vals = [pv_coverage_ratio[k] for k in plot_keys]
            y_vals = [cost_ratio[alloc][k] for k in plot_keys]
            scatter!(p_cost_ratio_vs_pv, x_vals, y_vals, label=label, color=color, alpha=1)
        end
    end
    display(p_cost_ratio_vs_pv)

    # Plot total MWh demand per client
    total_MWh_demand = Dict(client => sum(day_data["price_prod_demand_df"][!, Symbol(client)]) for client in plot_keys)
    p_total_demand = plot(
        #title="Total MWh Demand per Client",
        xlabel="Client", ylabel="Total Demand [MWh]", xticks=(1:length(plot_keys), plot_keys_alphabetic), xrotation=45, legend=:topright, tickfont=font(12), guidefont=font(14)
    )
    plot_vals_total_demand = [total_MWh_demand[k] for k in plot_keys]
    bar!(p_total_demand, 1:length(plot_keys), plot_vals_total_demand, label=false, color=:black)
    display(p_total_demand)

    # Socialized vs individualized plot
    # Check if we have both flat_rate and full_cost allocations
    if haskey(allocation_costs, "flat_rate") && haskey(allocation_costs, "full_cost")
        socialized_allocation = "flat_rate"
        individualized_allocation = "full_cost"
        individualization_steps = 0:0.05:1

        # Create mixed allocation DataFrame
        mixed_allocation_df = DataFrame(step = collect(individualization_steps))
        for client in clients
            flat = allocation_costs[socialized_allocation][client]
            indiv = allocation_costs[individualized_allocation][client]
            mixed_allocation_df[!, client] = (1 .- mixed_allocation_df.step) .* flat .+ mixed_allocation_df.step .* indiv
        end

        # Check stability (find where max excess becomes negative)
        negative_excess_step = nothing
        for row in eachrow(mixed_allocation_df)
            step_allocation = Dict(client => row[client] for client in clients)
            max_excess_step = check_stability(step_allocation, coalition_costs, clients)
            if max_excess_step < 0
                negative_excess_step = row[:step]
                break
            end
        end
        # Plot socialized vs individualized
        p_mixed = plot_socialized_vs_individualized(mixed_allocation_df, clients, day_data; negative_excess_step=negative_excess_step)
        display(p_mixed)
    end
end

function plot_cost_difference(allocation_costs, clients, system_data)
    # This function compares the cost of the most expensive allocation with the least expensive for each client
    # flat_rate, MCC, and VCG are excluded from this comparison
    filtered_allocations = filter(x -> x != "flat_rate", keys(allocation_costs))
    filtered_allocations = filter(x -> x != "MCC" , filtered_allocations)
    filtered_allocations = filter(x -> x != "VCG" , filtered_allocations)
    # Convert to vector for indexing
    filtered_allocations = collect(filtered_allocations)

    # Create alphabetic mapping for display
    client_name_mapping = create_alphabetic_client_mapping(clients)
    clients_alphabetic = [client_name_mapping[client] for client in clients]

    # Calculate cost per MWh for each allocation
    cost_MWh = Dict()
    for alloc in filtered_allocations
        if haskey(allocation_costs, alloc)
            cost_MWh[alloc] = scale_distribution(allocation_costs[alloc], system_data["price_prod_demand_df"], clients)
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
        xticks=(1:length(clients), clients_alphabetic),
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
        xticks=(1:length(clients), clients_alphabetic),
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
        println("$(clients_alphabetic[i])\t$(cheapest_alloc)\t$(round(cheapest_cost, digits=2))\t$(most_expensive_alloc)\t$(round(most_expensive_cost, digits=2))")
    end
end

"""
    plot_socialized_vs_individualized(mixed_allocation_df, clients, system_data; negative_excess_step=nothing)

Create a scatter plot showing cost per MWh vs individualization step for each client.

- `mixed_allocation_df`: DataFrame with columns 'step' and one column per client containing their costs
- `clients`: Array of client identifiers
- `system_data`: System data dictionary containing demand information
- `negative_excess_step`: Optional step value where max excess becomes negative (adds vertical line)

Returns the Plot object.
"""
function plot_socialized_vs_individualized(
    mixed_allocation_df,
    clients,
    system_data;
    negative_excess_step=nothing
)
    # Calculate cost per MWh for each client
    total_demand_by_client = Dict(client => sum(system_data["price_prod_demand_df"][!, client]) for client in clients)
    mixed_allocation_cost_per_mwh_df = DataFrame(step = mixed_allocation_df.step)
    for client in clients
        denom = total_demand_by_client[client]
        if isnothing(denom) || denom == 0
            mixed_allocation_cost_per_mwh_df[!, client] = fill(missing, nrow(mixed_allocation_df))
        else
            mixed_allocation_cost_per_mwh_df[!, client] = mixed_allocation_df[!, client] ./ denom
        end
    end

    # Flip sign to convert from the negative-is-cost convention to positive-for-display
    mixed_allocation_cost_per_mwh_df_plot = copy(mixed_allocation_cost_per_mwh_df)
    for client in clients
        mixed_allocation_cost_per_mwh_df_plot[!, client] = -mixed_allocation_cost_per_mwh_df[!, client]
    end

    p = plot(
        xlabel = "Individualization Grade",
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

    # Create color gradient from low to high cost: light green -> sand -> orange -> red
    final_costs = [mixed_allocation_cost_per_mwh_df_plot[end, client] for client in clients]
    cost_order = sortperm(final_costs)  # Low to high

    # Create gradient through all four colors
    n_clients = length(clients)
    if n_clients == 1
        palette_colors = [PALETTE_LIGHT_GREEN]
    elseif n_clients == 2
        palette_colors = [PALETTE_LIGHT_GREEN, PALETTE_RED]
    elseif n_clients == 3
        palette_colors = [PALETTE_LIGHT_GREEN, PALETTE_ORANGE, PALETTE_RED]
    else
        # Interpolate through all four colors
        n_per_segment = div(n_clients - 1, 3)
        remainder = (n_clients - 1) % 3  # 0, 1, or 2

        # Distribute remainder across the first segments
        n1 = n_per_segment + (remainder >= 1 ? 1 : 0) + 1
        n2 = n_per_segment + (remainder >= 2 ? 1 : 0) + 1
        n3 = n_per_segment + 1

        gradient1 = range(PALETTE_LIGHT_GREEN, stop=PALETTE_SAND, length=n1)
        gradient2 = range(PALETTE_SAND, stop=PALETTE_ORANGE, length=n2)
        gradient3 = range(PALETTE_ORANGE, stop=PALETTE_RED, length=n3)

        # Combine gradients, removing duplicate intermediate points
        color_gradient = vcat(collect(gradient1)[1:end-1], collect(gradient2)[1:end-1], collect(gradient3))
        # Order colors by each client's final cost rank (low to high)
        palette_colors = [color_gradient[findfirst(==(i), cost_order)] for i in 1:length(clients)]
    end

    for (i, client) in enumerate(clients)
        plot!(p,
            mixed_allocation_cost_per_mwh_df_plot.step,
            mixed_allocation_cost_per_mwh_df_plot[!, client],
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
    if !isnothing(negative_excess_step)
        vline!(p, [negative_excess_step],
               color = PALETTE_GREEN,
               linestyle = :dash,
               linewidth = 3,
               label = "Line of Stability")
    end

    return p
end
