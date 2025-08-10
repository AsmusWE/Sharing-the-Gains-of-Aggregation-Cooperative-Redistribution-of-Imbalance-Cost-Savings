using CSV
using DataFrames
using TimeZones
using Dates
using Plots

# =========================
# 1. Data Loading & Setup
# =========================
# --- Load demand data ---
demand = CSV.read("Data/consumption_data.csv", DataFrame)
demand[!, :HourUTC_datetime] = DateTime.(demand[:, :datetime_cet], DateFormat("yyyy-mm-dd HH:MM:SSz")) .- Hour(1)
select!(demand, Not(:datetime_cet))
demand[!, :Z] .= 0

# --- Define PV ownership ---
pvOwnershipDF = CSV.read("Data/Asset_master_data_asmus.csv", DataFrame; decimal=',')
clientPVOwnership = Dict(String(row.Customer) => row.a_ppa_pct for row in eachrow(pvOwnershipDF))
# Note: Z is the solar park owner

# --- Load and rescale PV production ---
pvProduction = CSV.read("Data/ProductionMunicipalityHour.csv", DataFrame; decimal=',')
pvProduction[!, :HourUTC_datetime] = DateTime.(pvProduction[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
plant_size = 14.0 # MW
old_plant_size = maximum(pvProduction[:, :SolarMWh])
rename!(pvProduction, :SolarMWh => :SolarMWh_unscaled)
pvProduction[!, :SolarMWh] = pvProduction[!, :SolarMWh_unscaled] .* plant_size / old_plant_size
pvProduction = select(pvProduction, [:HourUTC_datetime, :SolarMWh])

# --- Combine demand and PV production ---
combinedData = innerjoin(pvProduction, demand, on=:HourUTC_datetime)

# --- Prepare client list ---
clients = sort(collect(keys(clientPVOwnership)))

# --- Load and rescale PV forecast ---
pv_forecast = CSV.read("Data/Solar_Forecasts_Hour.csv", DataFrame; decimal=',')
pv_forecast[!, :HourUTC_datetime] = DateTime.(pv_forecast[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
rename!(pv_forecast, :ForecastCurrent => :ForecastCurrent_unscaled)
old_plant_size = maximum(pv_forecast[:, :ForecastCurrent_unscaled])
pv_forecast[!, :PVForecast] = pv_forecast[!, :ForecastCurrent_unscaled] .* plant_size / old_plant_size
pv_forecast = select(pv_forecast, [:HourUTC_datetime, :PVForecast])

# --- Merge forecast with combined data ---
combinedData = innerjoin(combinedData, pv_forecast, on=:HourUTC_datetime)

# --- Filter clients with missing data ---
# Use the combined data time range to check for missing values consistently
time_range = combinedData[:, :HourUTC_datetime]
demand_filtered = filter(row -> row.HourUTC_datetime in time_range, demand)

missing_data_counts = Dict(client => count(ismissing, demand_filtered[:, client]) for client in clients if client in names(demand_filtered))
clients_without_missing_data = filter(client -> haskey(missing_data_counts, client) && missing_data_counts[client] == 0, clients)
# --- Filter combined data to include only clients without missing data ---
combinedData = select(combinedData, Cols(:HourUTC_datetime, :SolarMWh, clients_without_missing_data..., :PVForecast))
#demand = select(demand, Cols(:HourUTC_datetime, :Z, clients_without_missing_data...))

# =========================
# 2. Identify Missing Demand Data
# =========================
# Identify clients with missing data
clients_with_missing_data = filter(client -> missing_data_counts[client] > 0, clients)
clients_with_missing_data = clients
if !isempty(clients_with_missing_data)
    println("Clients with missing data:")
    for client in clients_with_missing_data
        println("  $client: $(missing_data_counts[client]) missing values")
    end
    
    # Create a plot showing missing data patterns over time
    # Calculate height based on number of clients (minimum 600, add 25 per client)
    plot_height = max(600, 300 + 15 * length(clients_with_missing_data))
    p = plot(title="Missing Demand Data Over Time, Line is Missing Hours", 
             xlabel="Time (UTC)", ylabel="Client",
             legend=:topright, size=(1000, plot_height),
             titlefontsize=10, guidefontsize=8, tickfontsize=5, legendfontsize=6,
             left_margin=80Plots.px, bottom_margin=50Plots.px)
    
    # For each client with missing data, create a binary time series
    for (i, client) in enumerate(clients_with_missing_data)
        # Create binary indicator for missing data using filtered demand
        missing_indicator = ismissing.(demand_filtered[:, client])
        
        # Get time periods where data is missing
        missing_times = demand_filtered[missing_indicator, :HourUTC_datetime]
        
        if !isempty(missing_times)
            # Group consecutive missing periods
            sorted_times = sort(missing_times)
            
            # Find breaks in consecutive hours (gaps > 1 hour)
            time_diffs = diff(sorted_times)
            break_indices = findall(t -> t > Hour(1), time_diffs)
            
            # Get a consistent color for this client
            client_color = palette(:auto)[((i-1) % 10) + 1]
            
            # Split into continuous segments
            start_idx = 1
            for break_idx in break_indices
                end_idx = break_idx
                segment_times = sorted_times[start_idx:end_idx]
                segment_y = fill(i, length(segment_times))
                
                plot!(p, segment_times, segment_y, 
                      label=start_idx == 1 ? "$client ($(missing_data_counts[client]) missing hours)" : "",
                      linewidth=5, alpha=0.8, color=client_color)
                start_idx = break_idx + 1
            end
            
            # Plot the last segment
            if start_idx <= length(sorted_times)
                segment_times = sorted_times[start_idx:end]
                segment_y = fill(i, length(segment_times))
                
                plot!(p, segment_times, segment_y, 
                      label=start_idx == 1 ? "$client ($(missing_data_counts[client]) missing hours)" : "",
                      linewidth=5, alpha=0.8, color=client_color)
            end
        end
    end
    
    # Set y-axis to show client names with better spacing
    yticks!(p, 1:length(clients_with_missing_data), clients_with_missing_data)
    
    # Adjust y-axis limits to provide padding
    ylims!(p, 0.5, length(clients_with_missing_data) + 0.5)
    
    display(p)
    
    # Also create a summary plot showing missing data counts as bars
    p2 = bar(clients_with_missing_data, 
             [missing_data_counts[client] for client in clients_with_missing_data],
             title="Total Missing Data Count by Client",
             xlabel="Client", ylabel="Number of Missing Data Points",
             xrotation=45, size=(800, 500))
    
    display(p2)
    
    # Save plots
    savefig(p, "Results/missing_data_timeline.png")
    savefig(p2, "Results/missing_data_counts.png")
    println("Plots saved to Results/missing_data_timeline.png and Results/missing_data_counts.png")
else
    println("No clients have missing data!")
end


# =========================
# 3. Load Price Data
# =========================

# --- Change to 15 minute resolution for combinedData ---
value_cols = names(combinedData, Not(:HourUTC_datetime))
N = nrow(combinedData)
repeats = 4
# Repeat each row 4 times
expanded = combinedData[repeat(1:N, inner=repeats), :]
# Add 15-min offset to each repeated row
expanded.:HourUTC_datetime .+= Minute.(15 .* repeat(0:3, outer=N))
# Divide value columns by 4
expanded[:, value_cols] .= expanded[:, value_cols] ./ 4
combinedData = expanded
sort!(combinedData, :HourUTC_datetime)

# --- Change demand to 15 minute resolution in the same way ---
demand_value_cols = names(demand, Not([:HourUTC_datetime, :Z]))
N_demand = nrow(demand)
expanded_demand = demand[repeat(1:N_demand, inner=repeats), :]
expanded_demand.:HourUTC_datetime .+= Minute.(15 .* repeat(0:3, outer=N_demand))
expanded_demand[:, demand_value_cols] .= expanded_demand[:, demand_value_cols] ./ 4
demand = expanded_demand
sort!(demand, :HourUTC_datetime)

# --- Add price data ---
priceData = CSV.read("Data/ImbalancePrice.csv", DataFrame, decimal=',')
priceData[!, :HourUTC_datetime] = DateTime.(priceData[:, :TimeUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
priceData = select(priceData, [:HourUTC_datetime, :ImbalancePriceEUR, :SpotPriceEUR, :DominatingDirection])
priceData[!, :ImbalanceSpreadEUR] = priceData[!, :ImbalancePriceEUR] .- priceData[!, :SpotPriceEUR]


# =========================
# 4. Identify Missing Price Data
# =========================

# Count missing values in price data
price_columns = [:ImbalancePriceEUR, :SpotPriceEUR]
missing_price_counts = Dict(col => count(ismissing, priceData[:, col]) for col in price_columns)

println("\nMissing Price Data Analysis:")
println("="^50)
for col in price_columns
    missing_count = missing_price_counts[col]
    total_count = nrow(priceData)
    missing_pct = round(missing_count / total_count * 100, digits=2)
    println("$col: $missing_count missing values ($missing_pct%)")
end

# Identify time periods with missing price data
if any(values(missing_price_counts) .> 0)
    println("\nDetailed Missing Price Data Analysis:")
    
    # For each price column, find missing time periods
    for col in price_columns
        missing_count = missing_price_counts[col]
        if missing_count > 0
            println("\n--- $col ---")
            missing_mask = ismissing.(priceData[:, col])
            missing_times = priceData[missing_mask, :HourUTC_datetime]
            
            if !isempty(missing_times)
                sorted_missing_times = sort(missing_times)
                
                # Group consecutive missing periods
                time_diffs = diff(sorted_missing_times)
                break_indices = findall(t -> t > Hour(1), time_diffs)
                
                # Identify continuous missing periods
                start_idx = 1
                period_count = 1
                
                for break_idx in break_indices
                    end_idx = break_idx
                    period_start = sorted_missing_times[start_idx]
                    period_end = sorted_missing_times[end_idx]
                    period_duration = end_idx - start_idx + 1
                    
                    println("  Period $period_count: $period_start to $period_end ($period_duration hours)")
                    start_idx = break_idx + 1
                    period_count += 1
                end
                
                # Handle the last period
                if start_idx <= length(sorted_missing_times)
                    period_start = sorted_missing_times[start_idx]
                    period_end = sorted_missing_times[end]
                    period_duration = length(sorted_missing_times) - start_idx + 1
                    
                    println("  Period $period_count: $period_start to $period_end ($period_duration hours)")
                end
            end
        end
    end
    
    # Create visualization of missing price data
    println("\nCreating missing price data visualization...")
    
    
    p_price = plot(title="Missing Price Data Over Time", 
                   xlabel="Time (UTC)", ylabel="Price Variable",
                   legend=:topright,
                   titlefontsize=12, guidefontsize=10, tickfontsize=8, legendfontsize=8,
                   yrotation=90, xrotation=0, rightmargin=20Plots.px)
    
    # Plot missing data for each price column
    for (i, col) in enumerate(price_columns)
        missing_mask = ismissing.(priceData[:, col])
        missing_times = priceData[missing_mask, :HourUTC_datetime]
        
        if !isempty(missing_times)
            sorted_times = sort(missing_times)
            
            # Group consecutive missing periods for plotting
            time_diffs = diff(sorted_times)
            break_indices = findall(t -> t > Hour(1), time_diffs)
            
            # Get a color for this variable
            var_color = palette(:auto)[((i-1) % 10) + 1]
            
            # Plot each continuous segment as scatter points
            start_idx = 1
            for break_idx in break_indices
                end_idx = break_idx
                segment_times = sorted_times[start_idx:end_idx]
                segment_y = fill(i, length(segment_times))
                
                scatter!(p_price, segment_times, segment_y, 
                         label=start_idx == 1 ? "$col ($(missing_price_counts[col]) missing)" : "",
                         markersize=4, alpha=0.8, color=var_color)
                start_idx = break_idx + 1
            end
            
            # Plot the last segment as scatter points
            if start_idx <= length(sorted_times)
                segment_times = sorted_times[start_idx:end]
                segment_y = fill(i, length(segment_times))
                
                scatter!(p_price, segment_times, segment_y, 
                         label=start_idx == 1 ? "$col ($(missing_price_counts[col]) missing)" : "",
                         markersize=4, alpha=0.8, color=var_color)
            end
        end
    end
    
    # Set y-axis to show price variable names
    yticks!(p_price, 1:length(price_columns), string.(price_columns))
    ylims!(p_price, 0.5, length(price_columns) + 0.5)
    
    # Add invisible points at the min and max dates to force the x-axis range
    min_date = minimum(priceData[:, :HourUTC_datetime])
    max_date = maximum(priceData[:, :HourUTC_datetime])
    plot!(p_price, [min_date, max_date], [0.4, 0.4], alpha=0, label="")
    
    display(p_price)
    
    # Create summary bar chart for missing price data
    missing_counts = [missing_price_counts[col] for col in price_columns]
    max_count = maximum(missing_counts)
    p_price_bar = bar(string.(price_columns), 
                      missing_counts,
                      title="Missing Price Data Count by Variable",
                      xlabel="Price Variable", ylabel="Number of Missing Values",
                      xrotation=45,
                      color=palette(:auto)[1:length(price_columns)],
                      yticks=0:max(1, div(max_count, 10)):max_count,
                      legend = false)
    
    display(p_price_bar)
    
    # Save price data plots
    savefig(p_price, "Results/missing_price_data_timeline.png")
    savefig(p_price_bar, "Results/missing_price_data_counts.png")
    println("Price data plots saved to Results/missing_price_data_timeline.png and Results/missing_price_data_counts.png")
    
else
    println("No missing values found in price data!")
end

# =========================
# 5. Analyze DominatingDirection vs ImbalanceSpread Consistency
# =========================

println("\nAnalyzing DominatingDirection vs ImbalanceSpread consistency...")
println("="^60)

# Filter out rows with missing data for this analysis
complete_price_data = dropmissing(priceData, [:DominatingDirection, :ImbalanceSpreadEUR])

if nrow(complete_price_data) > 0
    # Create sign indicators
    # DominatingDirection: assuming positive values indicate one direction, negative another
    # ImbalanceSpread: positive when imbalance price > spot price, negative otherwise
    
    # Check what values DominatingDirection takes
    unique_directions = unique(complete_price_data[:, :DominatingDirection])
    println("Unique DominatingDirection values: ", unique_directions)
    
    # Analyze sign consistency
    inconsistent_rows = []
    
    for row in eachrow(complete_price_data)
        direction = row.DominatingDirection
        spread = row.ImbalanceSpreadEUR
        
        # Skip if either value is exactly zero (ambiguous case)
        if direction == 0 || spread == 0
            continue
        end
        
        # Check if signs are inconsistent
        # Assuming DominatingDirection follows the same sign convention as ImbalanceSpread
        direction_sign = sign(direction)
        spread_sign = sign(spread)
        
        if direction_sign != spread_sign
            push!(inconsistent_rows, (
                time = row.HourUTC_datetime,
                direction = direction,
                spread = spread,
                direction_sign = direction_sign,
                spread_sign = spread_sign
            ))
        end
    end
    
    # Report results
    total_non_zero = nrow(filter(row -> row.DominatingDirection != 0 && row.ImbalanceSpreadEUR != 0, complete_price_data))
    inconsistent_count = length(inconsistent_rows)
    consistency_rate = round((total_non_zero - inconsistent_count) / total_non_zero * 100, digits=2)
    
    println("Total data points with non-zero values: $total_non_zero")
    println("Inconsistent sign pairs: $inconsistent_count")
    println("Consistency rate: $consistency_rate%")
    
    if inconsistent_count > 0
        println("\nFirst 10 inconsistent cases:")
        for (i, row) in enumerate(inconsistent_rows[1:min(10, inconsistent_count)])
            println("  $(row.time): Direction=$(row.direction) ($(row.direction_sign)), Spread=$(round(row.spread, digits=2)) ($(row.spread_sign))")
        end
        
        if inconsistent_count > 10
            println("  ... and $(inconsistent_count - 10) more cases")
        end
        
        # Create a scatter plot to visualize the relationship
        p_consistency = scatter(complete_price_data[:, :DominatingDirection], 
                               complete_price_data[:, :ImbalanceSpreadEUR],
                               title="DominatingDirection vs ImbalanceSpread",
                               xlabel="DominatingDirection", 
                               ylabel="ImbalanceSpread (EUR)",
                               alpha=0.6, markersize=2,
                               label="All data points")
        
        # Highlight inconsistent points
        if !isempty(inconsistent_rows)
            inconsistent_directions = [row.direction for row in inconsistent_rows]
            inconsistent_spreads = [row.spread for row in inconsistent_rows]
            
            scatter!(p_consistency, inconsistent_directions, inconsistent_spreads,
                    color=:red, markersize=3, alpha=0.8,
                    label="Inconsistent signs ($inconsistent_count points)")
        end
        
        # Add quadrant lines
        vline!(p_consistency, [0], color=:black, linestyle=:dash, alpha=0.5, label="")
        hline!(p_consistency, [0], color=:black, linestyle=:dash, alpha=0.5, label="")
        
        display(p_consistency)
        
        # Save the plot
        savefig(p_consistency, "Results/direction_spread_consistency.png")
        println("Consistency plot saved to Results/direction_spread_consistency.png")
        
        # Create a time series plot of inconsistent points
        if !isempty(inconsistent_rows)
            inconsistent_times = [row.time for row in inconsistent_rows]
            inconsistent_spreads_ts = [row.spread for row in inconsistent_rows]
            
            p_timeline = scatter(inconsistent_times, inconsistent_spreads_ts,
                               title="Timeline of Direction-Spread Inconsistencies",
                               xlabel="Time (UTC)", 
                               ylabel="ImbalanceSpread (EUR)",
                               color=:red, markersize=3, alpha=0.8,
                               label="Inconsistent points")
            
            hline!(p_timeline, [0], color=:black, linestyle=:dash, alpha=0.5, label="")
            
            display(p_timeline)
            savefig(p_timeline, "Results/inconsistency_timeline.png")
            println("Timeline plot saved to Results/inconsistency_timeline.png")
        end
    else
        println("No inconsistencies found! All non-zero DominatingDirection and ImbalanceSpread values have consistent signs.")
    end
else
    println("No complete price data available for consistency analysis.")
end



