using CSV
using DataFrames
using Dates, Statistics
using Random

const DATA_PUBLIC_DIR = joinpath(@__DIR__, "..", "data", "public")
const DATA_PRIVATE_DIR = joinpath(@__DIR__, "..", "data", "private")

function demand_scaling!(demand, clients; rng = Random.default_rng())
    # Scale demand data in place - each client gets one random scaling factor (±10%) applied to all timesteps
    for client in clients
         scaling_factor = 1 + 0.1 * randn(rng)  # One random factor per client
         demand[!, Symbol(client)] .= demand[!, Symbol(client)] .* scaling_factor
    end
    return demand
end

"""
    load_data() -> Dict, Vector{String}, DataFrame

Load and preprocess demand, PV production, price, and forecast data for all clients.
Returns `(system_data, clients_without_missing_data, demand)`, where `system_data` is a
dictionary with the combined system data, `clients_without_missing_data` is a vector of
clients with complete data, and `demand` is the raw (post-scaling) per-client demand DataFrame.

Note: this injects random per-client demand noise via `demand_scaling!` (±10% of each
client's demand, applied uniformly across all timesteps) using the global RNG. Call
`Random.seed!(...)` before `load_data()` if reproducible output is required.
"""
function load_data()
    # --- Load demand data ---
    demand = CSV.read(joinpath(DATA_PRIVATE_DIR, "consumption_data.csv"), DataFrame)
    demand[!, :HourUTC_datetime] = DateTime.(demand[!, :datetime_cet], DateFormat("yyyy-mm-dd HH:MM:SSz")) .- Hour(1) # Fixed (non-DST-aware) CET -> UTC conversion (CET is UTC+1)
    select!(demand, Not(:datetime_cet))
    demand = demand_scaling!(demand, names(demand[!, Not([:HourUTC_datetime])]))

    # --- Define PV ownership ---
    pv_ownership_df = CSV.read(joinpath(DATA_PRIVATE_DIR, "Asset_master_data_asmus.csv"), DataFrame; decimal='.')
    client_pv_ownership = Dict(String(row.Customer) => row.a_ppa_pct for row in eachrow(pv_ownership_df))
    # Note: Z is the solar park owner

    # --- Load and rescale PV production ---
    pv_production = CSV.read(joinpath(DATA_PUBLIC_DIR, "ProductionMunicipalityHour.csv"), DataFrame; decimal=',')
    pv_production[!, :HourUTC_datetime] = DateTime.(pv_production[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
    # Drop all rows after January 2025 (keep up to 2025-01-31 23:59:59)
    # Done because new solar plants come online in 2025 changing the production profile
    cutoff = DateTime(2025, 2, 1)
    filter!(row -> row.HourUTC_datetime < cutoff, pv_production)
    plant_size = 14.0 # MW
    old_plant_size = maximum(pv_production[:, :SolarMWh])
    rename!(pv_production, :SolarMWh => :SolarMWh_unscaled)
    pv_production[!, :SolarMWh] = pv_production[!, :SolarMWh_unscaled] .* plant_size / old_plant_size
    pv_production = select(pv_production, [:HourUTC_datetime, :SolarMWh])

    # --- Combine demand and PV production ---
    combined_data = innerjoin(pv_production, demand, on=:HourUTC_datetime)
    # --- Prepare client list ---
    clients = sort(collect(keys(client_pv_ownership)))

    # --- Load and rescale PV forecast ---
    pv_forecast = CSV.read(joinpath(DATA_PUBLIC_DIR, "Solar_Forecasts_Hour.csv"), DataFrame; decimal=',')
    pv_forecast[!, :HourUTC_datetime] = DateTime.(pv_forecast[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
    rename!(pv_forecast, :ForecastCurrent => :ForecastCurrent_unscaled)
    old_plant_size = maximum(pv_forecast[:, :ForecastCurrent_unscaled])
    pv_forecast[!, :PVForecast] = pv_forecast[!, :ForecastCurrent_unscaled] .* plant_size / old_plant_size
    pv_forecast = select(pv_forecast, [:HourUTC_datetime, :PVForecast])

    # --- Merge forecast with combined data ---
    combined_data = innerjoin(combined_data, pv_forecast, on=:HourUTC_datetime)

    # --- Filter clients with missing data ---
    missing_data_counts = Dict(client => count(ismissing, combined_data[:, client]) for client in clients)
    clients_without_missing_data = filter(client -> missing_data_counts[client] == 0, clients)
    # --- Filter combined data to include only clients without missing data ---
    combined_data = select(combined_data, Cols(:HourUTC_datetime, :SolarMWh, clients_without_missing_data..., :PVForecast))
    demand = select(demand, Cols(:HourUTC_datetime, clients_without_missing_data...))

    # First load ImbalancePrice.csv data (15-minute resolution) and aggregate to hourly
    imbalance_price_from_detail = CSV.read(joinpath(DATA_PUBLIC_DIR, "ImbalancePrice.csv"), DataFrame, decimal=',')
    imbalance_price_from_detail[!, :HourUTC_datetime] = DateTime.(imbalance_price_from_detail[:, :TimeUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
    # Round down to the hour to aggregate 15-minute data
    imbalance_price_from_detail[!, :HourUTC_datetime] = floor.(imbalance_price_from_detail[!, :HourUTC_datetime], Hour(1))
    # Aggregate by taking the mean of the 15-minute values within each hour
    # Handle missing values by using skipmissing in the aggregation
    imbalance_price_from_detail = combine(groupby(imbalance_price_from_detail, :HourUTC_datetime),
                                     :ImbalancePriceEUR => (x -> mean(skipmissing(x))) => :ImbalancePriceEUR,
                                     :SpotPriceEUR => (x -> mean(skipmissing(x))) => :SpotPriceEUR)


    # Then load RegulatingBalancePowerdata.csv (hourly data) to supplement
    imbalance_price_from_hourly = CSV.read(joinpath(DATA_PUBLIC_DIR, "RegulatingBalancePowerdata.csv"), DataFrame, decimal=',')
    imbalance_price_from_hourly[!, :HourUTC_datetime] = DateTime.(imbalance_price_from_hourly[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
    imbalance_price_from_hourly = select(imbalance_price_from_hourly, [:HourUTC_datetime, :ImbalancePriceEUR])

    # Combine the two imbalance price datasets, prioritizing the detailed data
    # Use anti-join to get only the hours not already covered by the detailed data
    additional_imbalance_data = antijoin(imbalance_price_from_hourly, imbalance_price_from_detail, on=:HourUTC_datetime)
    imbalance_price_data = vcat(imbalance_price_from_detail, additional_imbalance_data, cols=:intersect)

    # Load spot price data from Elspotprices.csv
    spot_price_from_elspot = CSV.read(joinpath(DATA_PUBLIC_DIR, "Elspotprices.csv"), DataFrame, decimal=',')
    spot_price_from_elspot[!, :HourUTC_datetime] = DateTime.(spot_price_from_elspot[:, :HourUTC], DateFormat("yyyy-mm-dd HH:MM:SS"))
    spot_price_from_elspot = select(spot_price_from_elspot, [:HourUTC_datetime, :SpotPriceEUR])

    # Extract spot price data from ImbalancePrice.csv (already aggregated in imbalance_price_from_detail)
    spot_price_from_imbalance = select(imbalance_price_from_detail, [:HourUTC_datetime, :SpotPriceEUR])

    # Combine spot price data, prioritizing Elspot data where available
    # Use anti-join to get only the hours not already covered by Elspot data
    additional_spot_data = antijoin(spot_price_from_imbalance, spot_price_from_elspot, on=:HourUTC_datetime)
    spot_price_data = vcat(spot_price_from_elspot, additional_spot_data, cols=:intersect)
    # Join the price data on datetime first, then calculate spread
    # Use leftjoin to keep all imbalance data
    price_data = leftjoin(imbalance_price_data, spot_price_data, on=:HourUTC_datetime)

    # Print missing value summary for SpotPriceEUR and ImbalancePriceEUR
    n_missing_spot = count(ismissing, price_data[!, :SpotPriceEUR])
    n_missing_imbalance = count(ismissing, price_data[!, :ImbalancePriceEUR])
    println("Missing SpotPriceEUR values before fill: $n_missing_spot")
    println("Missing ImbalancePriceEUR values before fill: $n_missing_imbalance")

    # Handle missing values: If either spot price or imbalance price is missing, set both to 0
    missing_mask = ismissing.(price_data[!, :SpotPriceEUR]) .| ismissing.(price_data[!, :ImbalancePriceEUR])
    price_data[!, :SpotPriceEUR] = ifelse.(missing_mask, 0.0, coalesce.(price_data[!, :SpotPriceEUR], 0.0))
    price_data[!, :ImbalancePriceEUR] = ifelse.(missing_mask, 0.0, coalesce.(price_data[!, :ImbalancePriceEUR], 0.0))

    # Calculate spread
    price_data[!, :ImbalanceSpreadEUR] = price_data[!, :ImbalancePriceEUR] .- price_data[!, :SpotPriceEUR]

    # Generate DominantDirection column based on ImbalanceSpreadEUR (1 = positive spread, -1 = negative, 0 = none/missing)
    price_data[!, :DominantDirection] = ifelse.(coalesce.(price_data[!, :ImbalanceSpreadEUR], 0.0) .> 0, 1,
                                                        ifelse.(coalesce.(price_data[!, :ImbalanceSpreadEUR], 0.0) .< 0, -1, 0))

    price_data = select(price_data, [:HourUTC_datetime, :ImbalanceSpreadEUR, :DominantDirection, :SpotPriceEUR])

    # Final cleanup: replace any remaining missing values with 0.0 instead of removing rows
    price_data[!, :ImbalanceSpreadEUR] = coalesce.(price_data[!, :ImbalanceSpreadEUR], 0.0)
    price_data[!, :DominantDirection] = coalesce.(price_data[!, :DominantDirection], 0)
    price_data[!, :SpotPriceEUR] = coalesce.(price_data[!, :SpotPriceEUR], 0.0)

    combined_data = innerjoin(combined_data, price_data, on=:HourUTC_datetime)

    # --- Reverse the order of rows in combined_data ---
    combined_data = reverse(combined_data)

    # --- Collect system data ---
    system_data = Dict(
        "client_pv_ownership" => client_pv_ownership,
        "price_prod_demand_df" => combined_data
    )
    return system_data, clients_without_missing_data, demand
end
