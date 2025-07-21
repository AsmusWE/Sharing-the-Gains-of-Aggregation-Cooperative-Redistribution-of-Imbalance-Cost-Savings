using CSV
using DataFrames
using TimeZones

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
    missing_data_counts = Dict(client => count(ismissing, demand[:, client]) for client in clients)
    clients_without_missing_data = filter(client -> missing_data_counts[client] == 0, clients)

    # --- Filter combined data to include only clients without missing data ---
    combinedData = select(combinedData, Cols(:HourUTC_datetime, :SolarMWh, clients_without_missing_data..., :PVForecast))

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
    
    # Fill missing DominatingDirection values based on ImbalanceSpreadEUR
    priceData[!, :DominatingDirection] = coalesce.(priceData[!, :DominatingDirection], 
                                                  sign.(priceData[!, :ImbalanceSpreadEUR]))
    
    priceData = select(priceData, [:HourUTC_datetime, :ImbalanceSpreadEUR, :DominatingDirection])

    # Merge price data with combined data
    combinedData = innerjoin(combinedData, priceData, on=:HourUTC_datetime)


    # --- Collect system data ---
    systemData = Dict(
        #"demand" => demand,
        "clientPVOwnership" => clientPVOwnership,
        #"clients" => clients,
        "price_prod_demand_df" => combinedData
    )
    return systemData, clients_without_missing_data, demand
end

