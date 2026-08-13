# Tests for Data_import.jl

@testset "Data_import.jl" begin
    @testset "demand_scaling!" begin
        # Create a simple demand DataFrame
        using DataFrames
        Random.seed!(42)

        clients = ["A", "B", "C"]
        df = DataFrame(
            HourUTC_datetime = [DateTime(2024, 1, 1, i, 0, 0) for i in 0:4],
            A = [100.0, 110.0, 120.0, 130.0, 140.0],
            B = [80.0, 85.0, 90.0, 95.0, 100.0],
            C = [50.0, 55.0, 60.0, 65.0, 70.0]
        )

        # Store original values for comparison (demand_scaling! mutates df in place)
        original = Dict(client => copy(df[:, Symbol(client)]) for client in clients)

        # Apply demand scaling
        scaled_df = demand_scaling!(df, clients)

        # Check that each client's demand is scaled by a single constant multiplier
        for client in clients
            client_col = Symbol(client)
            scaling_factor = scaled_df[1, client_col] / original[client][1]

            # All values for this client should be scaled by the same factor
            for i in 1:nrow(df)
                @test isapprox(scaled_df[i, client_col], original[client][i] * scaling_factor; rtol=1e-10)
            end
        end

        # demand_scaling! mutates its argument in place
        @test scaled_df === df

        println("demand_scaling!: PASS")
    end
    
    # Note: load_data() is explicitly out of scope as it depends on NDA-gated data/private/
    # and is not portable to other checkouts/CI. Documented here for completeness.
    @testset "load_data - explicitly not tested" begin
        # This function depends on private data files that are not available in the test environment
        # Skipping this test as per the plan
        println("load_data: SKIPPED (requires NDA-gated private data)")
    end
end
