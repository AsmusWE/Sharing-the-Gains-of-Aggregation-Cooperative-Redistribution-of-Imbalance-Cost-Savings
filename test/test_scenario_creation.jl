# Tests for Scenario_creation.jl

@testset "Scenario_creation.jl" begin
    @testset "generate_dominant_direction" begin
        # Test with positive spread
        spread_pos = [10.0, 5.0, 3.0]
        dir_pos = generate_dominant_direction(spread_pos)
        @test all(dir_pos .== 1)
        
        # Test with negative spread
        spread_neg = [-10.0, -5.0, -3.0]
        dir_neg = generate_dominant_direction(spread_neg)
        @test all(dir_neg .== 0)
        
        # Test with zero spread (edge case - should be 0, not sign()-symmetric)
        spread_zero = [0.0, 0.0, 0.0]
        dir_zero = generate_dominant_direction(spread_zero)
        @test all(dir_zero .== 0)
        
        # Test with mixed spread
        spread_mixed = [10.0, -5.0, 0.0, 3.0, -2.0]
        dir_mixed = generate_dominant_direction(spread_mixed)
        @test dir_mixed[1] == 1
        @test dir_mixed[2] == 0
        @test dir_mixed[3] == 0
        @test dir_mixed[4] == 1
        @test dir_mixed[5] == 0
        
        println("generate_dominant_direction: PASS")
    end
    
    @testset "generate_scenarios_demand_rolling" begin
        # Test error cases which are easier to verify
        clients = ["A", "B"]
        start_date = DateTime(2024, 1, 1, 0, 0, 0)
        timestamps = [start_date + Hour(i) for i in 0:100]
        df = DataFrame(
            HourUTC_datetime = timestamps,
            A = [100.0 + i for i in 0:100],
            B = [80.0 + i for i in 0:100]
        )
        
        # Test missing start_hour error
        @test_throws ErrorException generate_scenarios_demand_rolling(
            clients, df, DateTime(2025, 1, 1, 0, 0, 0), 1; num_scenarios=3
        )
        
        println("generate_scenarios_demand_rolling (missing start_hour error): PASS")
        
        # Test insufficient history error (throws BoundsError)
        early_start = DateTime(2024, 1, 1, 0, 0, 0)
        @test_throws BoundsError generate_scenarios_demand_rolling(
            clients, df, early_start, 1; num_scenarios=3
        )
        
        println("generate_scenarios_demand_rolling (insufficient history error): PASS")
    end
    
    @testset "generate_scenarios_imbalance_spread" begin
        clients = ["A", "B", "C"]
        
        # Test error cases
        start_date = DateTime(2024, 1, 1, 0, 0, 0)
        timestamps = [start_date + Hour(i) for i in 0:100]
        
        # Create system_data manually for error testing
        df = DataFrame(
            HourUTC_datetime = timestamps,
            SolarMWh = [50.0 + i for i in 0:100],
            PVForecast = [50.0 + i for i in 0:100],
            ImbalanceSpreadEUR = [10.0 * (rand() - 0.5) for i in 0:100],
            DominantDirection = [ifelse(rand() > 0.5, 1, -1) for i in 0:100],
            SpotPriceEUR = [50.0 + 20.0 * (rand() - 0.5) for i in 0:100],
            A = [100.0 + i for i in 0:100],
            B = [80.0 + i for i in 0:100],
            C = [60.0 + i for i in 0:100]
        )

        client_pv_ownership = Dict("A" => 0.1, "B" => 0.1, "C" => 0.1)
        system_data = Dict(
            "price_prod_demand_df" => df,
            "client_pv_ownership" => client_pv_ownership
        )

        # Test missing start_hour error
        @test_throws ErrorException generate_scenarios_imbalance_spread(
            system_data, DateTime(2025, 1, 1, 0, 0, 0), 24; num_scenarios=5
        )

        println("generate_scenarios_imbalance_spread (missing start_hour error): PASS")

        # Test insufficient historical data error
        # data_length = start_idx - 1
        # start_hour = 2024-01-01T10:00:00, start_idx = 11, data_length = 10
        # scenario_length * num_scenarios = 24 * 5 = 120 > 10, so should error
        start_hour = DateTime(2024, 1, 1, 10, 0, 0)
        @test_throws ErrorException generate_scenarios_imbalance_spread(
            system_data, start_hour, 24; num_scenarios=5
        )
        
        println("generate_scenarios_imbalance_spread (insufficient data error): PASS")
    end
    
    @testset "generate_scenarios_demand" begin
        clients = ["A", "B"]
        start_date = DateTime(2024, 1, 1, 0, 0, 0)
        timestamps = [start_date + Hour(i) for i in 0:100]
        df = DataFrame(
            HourUTC_datetime = timestamps,
            A = [100.0 + i for i in 0:100],
            B = [80.0 + i for i in 0:100]
        )
        
        # Test missing start_hour error
        @test_throws ErrorException generate_scenarios_demand(
            clients, df, DateTime(2025, 1, 1, 0, 0, 0); num_scenarios=5
        )
        
        println("generate_scenarios_demand (missing start_hour error): PASS")
    end
end
