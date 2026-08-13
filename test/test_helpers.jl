# Test helpers - shared synthetic fixture builders
# Load all source files in the same order as scripts/common_setup.jl

include("../src/Data_import.jl")
include("../src/Scenario_creation.jl")
include("../src/Imbalance_functions.jl")
include("../src/Game_theoretic_functions.jl")
include("../src/Plotting_functions.jl")
include("../src/Types.jl")

using Dates, Random

"""
    create_synthetic_system_data(clients; T=8, seed=42) -> Dict{String, Any}

Create a small synthetic system_data dict for testing.
Returns a dict with all columns downstream functions expect:
- price_prod_demand_df: DataFrame with HourUTC_datetime, per-client demand,
  SolarMWh, PVForecast, ImbalanceSpreadEUR, DominantDirection, SpotPriceEUR
- client_pv_ownership: Dict mapping client names to PV ownership fractions
"""
function create_synthetic_system_data(clients; T=8, seed=42)
    Random.seed!(seed)

    # Generate T timestamps starting from a fixed date
    start_date = DateTime(2024, 1, 1, 0, 0, 0)
    timestamps = [start_date + Hour(i) for i in 0:T-1]

    # Create demand data for each client (positive values)
    demand_data = Dict{String, Vector{Float64}}()
    for client in clients
        demand_data[client] = rand(T) .* 100 .+ 50  # Demand between 50-150 MWh
    end

    # Create PV production data (SolarMWh)
    solar_mwh = [50.0 + 30.0 * sin(2π * i / T) for i in 0:T-1]  # Oscillating PV

    # Create PV forecast data (PVForecast)
    pv_forecast = solar_mwh .+ randn(T) .* 2  # Noisy forecast

    # Create imbalance spread (can be positive or negative)
    imbalance_spread = [10.0 * (rand() - 0.5) for _ in 1:T]

    # Create spot price
    spot_price = [50.0 + 20.0 * (rand() - 0.5) for _ in 1:T]

    # Create dominant direction based on spread sign
    dominant_direction = ifelse.(imbalance_spread .> 0, 1, ifelse.(imbalance_spread .< 0, -1, 0))

    # Build the DataFrame
    df_data = Dict(
        :HourUTC_datetime => timestamps,
        :SolarMWh => solar_mwh,
        :PVForecast => pv_forecast,
        :ImbalanceSpreadEUR => imbalance_spread,
        :DominantDirection => dominant_direction,
        :SpotPriceEUR => spot_price
    )

    # Add client demand columns
    for client in clients
        df_data[Symbol(client)] = demand_data[client]
    end

    df = DataFrame(df_data)

    # Create client PV ownership (uniform for simplicity)
    client_pv_ownership = Dict(client => 0.1 for client in clients)

    system_data = Dict(
        "price_prod_demand_df" => df,
        "client_pv_ownership" => client_pv_ownership
    )

    return system_data
end

"""
    create_synthetic_stochastic_data(system_data, clients; num_scenarios=5, seed=42) -> Dict{String, Any}

Create synthetic stochastic_data for testing.
"""
function create_synthetic_stochastic_data(system_data, clients; num_scenarios=5, seed=42)
    Random.seed!(seed)

    T = nrow(system_data["price_prod_demand_df"])

    # Create demand scenarios for each client
    demand_scenarios = Dict{String, Matrix{Float64}}()
    for client in clients
        base_demand = system_data["price_prod_demand_df"][:, Symbol(client)]
        # Add noise to create scenarios
        scenarios = [base_demand .* (1 .+ 0.1 .* randn(T)) for _ in 1:num_scenarios]
        demand_scenarios[client] = hcat(scenarios...)
    end

    # Create imbalance spread scenarios
    base_spread = system_data["price_prod_demand_df"][:, :ImbalanceSpreadEUR]
    imbalance_spread = [base_spread .* (1 .+ 0.2 .* randn(T))' for _ in 1:num_scenarios]
    imbalance_spread = vcat(imbalance_spread...)

    # Create spot price scenarios
    base_spot = system_data["price_prod_demand_df"][:, :SpotPriceEUR]
    spot_price = [base_spot .* (1 .+ 0.1 .* randn(T))' for _ in 1:num_scenarios]
    spot_price = vcat(spot_price...)

    # Generate dominant direction from spread (0/1 encoding as used in optimize_imbalance)
    dominant_direction_scenarios = ifelse.(imbalance_spread .> 0, 1, 0)

    stochastic_data = Dict(
        "demand_scenarios" => demand_scenarios,
        "imbalance_spread" => imbalance_spread,
        "spot_price" => spot_price,
        "dominant_direction_scenarios" => dominant_direction_scenarios,
        "demand_forecast" => "scenarios",
        "pv_forecast" => "perfect"
    )

    return stochastic_data
end

"""
    create_synthetic_coalition_costs(clients; seed=42) -> Dict{Vector{String}, Float64}

Create coalition costs for all non-empty subsets of clients.
Costs are additive (no synergy) by default: c(S) = sum(c([i]) for i in S)
with some small random perturbation to avoid exact additivity.
"""
function create_synthetic_coalition_costs(clients; seed=42)
    Random.seed!(seed)

    # First create singleton costs (negative values, as costs are <= 0 in the codebase convention)
    singleton_costs = Dict{String, Float64}()
    for client in clients
        singleton_costs[client] = -(100 + 50 * rand())  # Negative cost (income)
    end

    # Generate costs for all non-empty subsets
    coalition_costs = Dict{Vector{String}, Float64}()

    # Use combinations to generate all non-empty subsets
    for k in 1:length(clients)
        for combo in combinations(clients, k)
            coalition = vec(combo)
            # Base cost is sum of singleton costs (additive)
            base_cost = sum(singleton_costs[client] for client in coalition)
            # Add small random perturbation
            perturbation = -1.0 * rand()  # Small negative perturbation
            coalition_costs[coalition] = base_cost + perturbation
        end
    end

    return coalition_costs, singleton_costs
end

"""
    create_synthetic_coalition_imbalances(clients, system_data; seed=42) -> Dict{Vector{String}, Vector{Float64}}

Create synthetic coalition-imbalances dict with time series for each coalition.
"""
function create_synthetic_coalition_imbalances(clients, system_data; seed=42)
    Random.seed!(seed)

    T = nrow(system_data["price_prod_demand_df"])
    coalition_imbalances = Dict{Vector{String}, Vector{Float64}}()

    # Generate singleton imbalances first
    client_imbalances = Dict{String, Vector{Float64}}()
    for client in clients
        demand = system_data["price_prod_demand_df"][:, Symbol(client)]
        pv = system_data["price_prod_demand_df"][:, :SolarMWh] .* system_data["client_pv_ownership"][client]
        # Imbalance = demand - PV (simple model)
        client_imbalances[client] = demand - pv .+ randn(T) .* 5
    end

    # Generate for all non-empty subsets
    for k in 1:length(clients)
        for combo in combinations(clients, k)
            coalition = vec(combo)
            # Sum of individual imbalances
            imbalance = sum(client_imbalances[client] for client in coalition)
            coalition_imbalances[coalition] = imbalance
        end
    end

    return coalition_imbalances
end

"""
    create_test_fixtures(; num_clients=3, T=6, seed=42)

Create a complete set of synthetic fixtures for testing.
Returns: (system_data, stochastic_data, clients, coalition_costs, coalition_imbalances)
"""
function create_test_fixtures(; num_clients=3, T=6, seed=42)
    clients = ["Client_$(i)" for i in 1:num_clients]
    system_data = create_synthetic_system_data(clients; T=T, seed=seed)
    stochastic_data = create_synthetic_stochastic_data(system_data, clients; num_scenarios=3, seed=seed+1)
    coalition_costs, _ = create_synthetic_coalition_costs(clients; seed=seed+2)
    coalition_imbalances = create_synthetic_coalition_imbalances(clients, system_data; seed=seed+3)

    return system_data, stochastic_data, clients, coalition_costs, coalition_imbalances
end
