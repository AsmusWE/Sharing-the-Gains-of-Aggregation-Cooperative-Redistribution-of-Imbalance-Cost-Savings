include("Imbalance_functions.jl")

function generate_scenarios_demand(clients, demandDF, start_hour; num_scenarios = 50)
    # Find the index of the first value after the start_hour in the demandDF
    start_idx = findfirst(demandDF[:, :HourUTC_datetime] .> start_hour)
    if start_idx === nothing
        error("No value after start_hour $start_hour found in demandDF[:HourUTC_datetime]")
    end
    scen_length = length(demandDF[1:start_idx, :HourUTC_datetime])  # Length of the historical data before start_hour
    # Filter the demandDF to only include data before the start_hour
    demandDF = demandDF[1:start_idx, :]
    
    # Create a dictionary to store the scenarios
    total_scenarios = div(size(demandDF)[1], scen_length, RoundDown)
    scenarios_dict = Dict()

    for client in clients
        # Looping over weekdays
        for w in 1:7
            key = tuple(client, w)
            # Initialize an array to store scenarios for the client
            client_scenarios = zeros(scen_length, total_scenarios)
            # Determine weekday from "HourUTC_datetime" column
            # Assuming "HourUTC_datetime" is of DateTime type
            weekday_numbers = dayofweek.(demandDF[:, :HourUTC_datetime])  # 1=Monday, ..., 7=Sunday
            weekday_indices = findall(weekday_numbers .== w)
            # Number of scenarios for this weekday
            weekday_total_scenarios = div(length(weekday_indices), scen_length, RoundDown)
            # Only proceed if there are enough samples for this weekday
            if weekday_total_scenarios == 0
                println("Not enough data for client $client on weekday $w. Skipping.")
                continue
            end
            # Initialize array for this weekday
            client_scenarios = zeros(scen_length, weekday_total_scenarios)
            for i in 1:weekday_total_scenarios
                idx_range = weekday_indices[(i-1)*scen_length+1 : i*scen_length]
                client_scenarios[:, i] = demandDF[!, client][idx_range]
            end
            # Randomly select num_scenarios from the generated scenarios
            selected_indices = rand(1:weekday_total_scenarios, min(num_scenarios, weekday_total_scenarios))
            scenarios_dict[key] = client_scenarios[:, selected_indices]
        end
    end

    return scenarios_dict
end

function generate_scenarios_demand_rolling(clients, demandDF, start_hour, sim_days; num_scenarios = 5)
    # Find the length of the data after the start_hour in the demandDF
    start_idx = findfirst(demandDF[:, :HourUTC_datetime] .> start_hour)
    if start_idx === nothing
        error("No value after start_hour $start_hour found in demandDF[:HourUTC_datetime]")
    end
    scen_length = sim_days * 96  # 96 time steps per day, sim_days days
    scenarios_dict = Dict()
    scenario_offset = 96*7 # 96 time steps per day, 7 days in a week. 
    for client in clients
        # Initialize an array to store scenarios for the client
        client_scenarios = zeros(scen_length, num_scenarios)
        # Loop over the number of scenarios
        for i in 1:num_scenarios
            # Scenario i is the real data shifted by i weeks
            client_scenarios[:, i] = demandDF[start_idx - i*scenario_offset : start_idx - i*scenario_offset + scen_length - 1, client]
        end
        scenarios_dict[client] = client_scenarios
    end

    return scenarios_dict
end

function generate_scenarios_imbalance_spread(systemData, start_hour, scenario_length; num_scenarios = 100)
    imbalance_spread = systemData["price_prod_demand_df"][:, :ImbalanceSpreadEUR]
    scenarios = zeros(num_scenarios, scenario_length)

    # Only keep data from before the start_hour
    start_idx = findfirst(systemData["price_prod_demand_df"][:, :HourUTC_datetime] .> start_hour)
    if start_idx === nothing
        error("No value after start_hour $start_hour found in price_prod_demand_df[:HourUTC_datetime]")
    end
    data_length = start_idx - 1  # Length of the data before the start_hour
    imbalance_spread = imbalance_spread[1:data_length]

    # Check if we have enough data to generate scenarios of the required length
    if data_length < scenario_length* num_scenarios
        error("Not enough historical data ($(data_length) points) to generate $(num_scenarios) scenarios of length $(scenario_length)")
    end

    # Generate scenarios by randomly selecting consecutive sequences from the historical data
    for i in 1:num_scenarios
        # Randomly select a starting index that is a multiple of 96 (ensuring start at 00:00)
        # and ensuring we have enough data for the full scenario length
        max_start_idx = data_length - scenario_length + 1
        # Find the maximum multiple of 96 that is <= max_start_idx
        max_start_multiple_96 = div(max_start_idx - 1, 96) * 96 + 1
        # Randomly select from valid multiples of 96
        num_valid_starts = div(max_start_multiple_96 - 1, 96) + 1
        random_multiple = rand(0:num_valid_starts-1)
        start_idx = random_multiple * 96 + 1
        scenarios[i, :] = imbalance_spread[start_idx:start_idx + scenario_length - 1]
    end

    return scenarios
end

function generate_dominant_direction(spreadScenarios)
    # Generate a DominatingDirection column based on ImbalanceSpreadEUR
    # 1 for positive price spread, 0 for negative price spread
    # Should be tied to spreadScenarios, pre-generated to speed up optimization
    return ifelse.(spreadScenarios .> 0, 1, 0)
end