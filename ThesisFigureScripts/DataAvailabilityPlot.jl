using CSV
using DataFrames
using TimeZones
using Dates
using Plots


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

# --- Plot missing data patterns ---
# Identify clients with missing data
clients_with_missing_data = filter(client -> missing_data_counts[client] > 0, clients)

if !isempty(clients_with_missing_data)
    println("Clients with missing data:")
    for client in clients_with_missing_data
        println("  $client: $(missing_data_counts[client]) missing values")
    end
    
    # Create a plot showing missing data patterns over time
    p = plot(title="Missing Data Patterns Over Time, Line is Missing Hours", 
             xlabel="Time (UTC)", ylabel="Client",
             legend=:topright, size=(800, 400),
             titlefontsize=10, guidefontsize=8, tickfontsize=6, legendfontsize=6)
    
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
                      linewidth=2, alpha=0.8, color=client_color)
                start_idx = break_idx + 1
            end
            
            # Plot the last segment
            if start_idx <= length(sorted_times)
                segment_times = sorted_times[start_idx:end]
                segment_y = fill(i, length(segment_times))
                
                plot!(p, segment_times, segment_y, 
                      label=start_idx == 1 ? "$client ($(missing_data_counts[client]) missing hours)" : "",
                      linewidth=2, alpha=0.8, color=client_color)
            end
        end
    end
    
    # Set y-axis to show client names
    yticks!(p, 1:length(clients_with_missing_data), clients_with_missing_data)
    
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




