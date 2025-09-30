using CSV
using DataFrames
using TimeZones
using Dates

"""
    load_data() -> Dict, Vector{String}

Load and preprocess demand, PV production, price, and forecast data for all clients.
Returns a dictionary with system data and a vector of clients without missing data.
"""
function load_data()
    # --- Load demand data ---
    demand = CSV.read("Data/consumption_data.csv", DataFrame)
    demand[!, :HourUTC_datetime] = DateTime.(demand[:, :datetime_cet], DateFormat("yyyy-mm-dd HH:MM:SSz")) .- Hour(1)
    select!(demand, Not(:datetime_cet))
    demand[!, :Z] .= 0

    # --- Define PV ownership ---
    pvOwnershipDF = CSV.read("Data/Asset_master_data_asmus.csv", DataFrame; decimal='.')
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
    firstHour = minimum(combinedData[:, :HourUTC_datetime])
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
    missing_data_counts = Dict(client => count(ismissing, combinedData[:, client]) for client in clients)
    clients_without_missing_data = filter(client -> missing_data_counts[client] == 0, clients)
    # --- Filter combined data to include only clients without missing data ---
    combinedData = select(combinedData, Cols(:HourUTC_datetime, :SolarMWh, clients_without_missing_data..., :PVForecast))
    demand = select(demand, Cols(:HourUTC_datetime, :Z, clients_without_missing_data...))

    fifteenMinRes = false
    if fifteenMinRes
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
        # Fill missing ImbalanceSpreadEUR values with 0.0
        #priceData[!, :ImbalanceSpreadEUR] = coalesce.(priceData[!, :ImbalanceSpreadEUR], 0.0)
        
        # Fill missing DominatingDirection values based on ImbalanceSpreadEUR
        #priceData[!, :DominatingDirection] = coalesce.(priceData[!, :DominatingDirection], 
        #                                              sign.(priceData[!, :ImbalanceSpreadEUR]))
        # Generate new DominatingDirection column based on ImbalanceSpreadEUR
        # This is done because of errors in the dominatingDirection data
        # If there are missing price values, dominatingDirection is set to 0
        priceData[!, :DominatingDirection] = ifelse.(coalesce.(priceData[!, :ImbalanceSpreadEUR], 0.0) .> 0, 1,
                                                            ifelse.(coalesce.(priceData[!, :ImbalanceSpreadEUR], 0.0) .< 0, -1, 0))
        
        priceData = select(priceData, [:HourUTC_datetime, :ImbalanceSpreadEUR, :DominatingDirection, :SpotPriceEUR])

        # Merge price data with combined data
        combinedData = innerjoin(combinedData, priceData, on=:HourUTC_datetime)
    else
        # First load ImbalancePrice.csv data (15-minute resolution) and aggregate to hourly
        imbalancePriceFromDetail = CSV.read("Data/ImbalancePrice.csv", DataFrame, decimal=',')
        imbalancePriceFromDetail[!, :HourUTC_datetime] = DateTime.(imbalancePriceFromDetail[:, :TimeUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
        # Round down to the hour to aggregate 15-minute data
        imbalancePriceFromDetail[!, :HourUTC_datetime] = floor.(imbalancePriceFromDetail[!, :HourUTC_datetime], Hour(1))
        # Aggregate by taking the mean of the 15-minute values within each hour
        # Handle missing values by using skipmissing in the aggregation
        imbalancePriceFromDetail = combine(groupby(imbalancePriceFromDetail, :HourUTC_datetime), 
                                         :ImbalancePriceEUR => (x -> mean(skipmissing(x))) => :ImbalancePriceEUR,
                                         :SpotPriceEUR => (x -> mean(skipmissing(x))) => :SpotPriceEUR)


        # Then load RegulatingBalancePowerdata.csv (hourly data) to supplement
        imbalancePriceFromHourly = CSV.read("Data/RegulatingBalancePowerdata.csv", DataFrame, decimal=',')
        imbalancePriceFromHourly[!, :HourUTC_datetime] = DateTime.(imbalancePriceFromHourly[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
        imbalancePriceFromHourly = select(imbalancePriceFromHourly, [:HourUTC_datetime, :ImbalancePriceEUR])
        
        # Combine the two imbalance price datasets, prioritizing the detailed data
        # Use anti-join to get only the hours not already covered by the detailed data
        additional_imbalance_data = antijoin(imbalancePriceFromHourly, imbalancePriceFromDetail, on=:HourUTC_datetime)
        imbalancePriceData = vcat(imbalancePriceFromDetail, additional_imbalance_data, cols=:intersect)
        
        # Load spot price data from Elspotprices.csv
        spotPriceFromElspot = CSV.read("Data/Elspotprices.csv", DataFrame, decimal=',')
        spotPriceFromElspot[!, :HourUTC_datetime] = DateTime.(spotPriceFromElspot[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
        spotPriceFromElspot = select(spotPriceFromElspot, [:HourUTC_datetime, :SpotPriceEUR])
        
        # Extract spot price data from ImbalancePrice.csv (already aggregated in imbalancePriceFromDetail)
        spotPriceFromImbalance = select(imbalancePriceFromDetail, [:HourUTC_datetime, :SpotPriceEUR])
        
        # Combine spot price data, prioritizing Elspot data where available
        # Use anti-join to get only the hours not already covered by Elspot data
        additional_spot_data = antijoin(spotPriceFromImbalance, spotPriceFromElspot, on=:HourUTC_datetime)
        spotPriceData = vcat(spotPriceFromElspot, additional_spot_data, cols=:intersect)
        n_missing_spot = count(ismissing, spotPriceData[!, :SpotPriceEUR])
        println("Missing SpotPriceEUR: ", n_missing_spot)
        # Join the price data on datetime first, then calculate spread
        # Use leftjoin to keep all imbalance data
        priceData = leftjoin(imbalancePriceData, spotPriceData, on=:HourUTC_datetime)

        # Print missing value summary for SpotPriceEUR and ImbalancePriceEUR
        n_missing_spot = count(ismissing, priceData[!, :SpotPriceEUR])
        n_missing_imbalance = count(ismissing, priceData[!, :ImbalancePriceEUR])
        println("Missing SpotPriceEUR: ", n_missing_spot)
        println("Missing ImbalancePriceEUR: ", n_missing_imbalance)

        # Handle missing values: If either spot price or imbalance price is missing, set both to 0
        missing_mask = ismissing.(priceData[!, :SpotPriceEUR]) .| ismissing.(priceData[!, :ImbalancePriceEUR])
        priceData[!, :SpotPriceEUR] = ifelse.(missing_mask, 0.0, coalesce.(priceData[!, :SpotPriceEUR], 0.0))
        priceData[!, :ImbalancePriceEUR] = ifelse.(missing_mask, 0.0, coalesce.(priceData[!, :ImbalancePriceEUR], 0.0))
        
        # Calculate spread
        priceData[!, :ImbalanceSpreadEUR] = priceData[!, :ImbalancePriceEUR] .- priceData[!, :SpotPriceEUR]

        #Generate DominatingDirection column based on ImbalanceSpreadEUR
        priceData[!, :DominatingDirection] = ifelse.(coalesce.(priceData[!, :ImbalanceSpreadEUR], 0.0) .> 0, 1,
                                                            ifelse.(coalesce.(priceData[!, :ImbalanceSpreadEUR], 0.0) .< 0, -1, 0))
        
        # Select final columns in the same order as the fifteenMinRes branch
        priceData = select(priceData, [:HourUTC_datetime, :ImbalanceSpreadEUR, :DominatingDirection, :SpotPriceEUR])
        
        # Final cleanup: replace any remaining missing values with 0.0 instead of removing rows
        priceData[!, :ImbalanceSpreadEUR] = coalesce.(priceData[!, :ImbalanceSpreadEUR], 0.0)
        priceData[!, :DominatingDirection] = coalesce.(priceData[!, :DominatingDirection], 0)
        priceData[!, :SpotPriceEUR] = coalesce.(priceData[!, :SpotPriceEUR], 0.0)
        
        combinedData = innerjoin(combinedData, priceData, on=:HourUTC_datetime)
    end

    # --- Reverse the order of rows in combinedData ---
    combinedData = reverse(combinedData)
    #println("First hour in data: ", combinedData[1, :HourUTC_datetime])
    #println("Last hour in data: ", combinedData[end, :HourUTC_datetime])

    # --- Collect system data ---
    systemData = Dict(
        #"demand" => demand,
        "clientPVOwnership" => clientPVOwnership,
        #"clients" => clients,
        "price_prod_demand_df" => combinedData
    )
    return systemData, clients_without_missing_data, demand
end

