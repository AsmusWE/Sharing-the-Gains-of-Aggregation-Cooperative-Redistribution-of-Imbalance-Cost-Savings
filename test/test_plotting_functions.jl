# Tests for Plotting_functions.jl
# Note: plot_results, plot_cost_difference, plot_socialized_vs_individualized are explicitly
# out of scope - rendering/IO-heavy (display, hardcoded savefig to CWD), not cleanly
# unit-testable without refactoring. Only the two pure helpers are tested here.

@testset "Plotting_functions.jl" begin
    @testset "create_alphabetic_client_mapping" begin
        # Test with 3 clients (within single letters)
        clients = ["X", "Y", "Z"]
        mapping = create_alphabetic_client_mapping(clients)
        @test mapping["X"] == "A"
        @test mapping["Y"] == "B"
        @test mapping["Z"] == "C"
        
        # Test with 26 clients (exactly at boundary)
        clients_26 = ["Client_$i" for i in 1:26]
        mapping_26 = create_alphabetic_client_mapping(clients_26)
        @test mapping_26["Client_1"] == "A"
        @test mapping_26["Client_26"] == "Z"
        
        # Test with 27 clients (first double-letter)
        clients_27 = ["Client_$i" for i in 1:27]
        mapping_27 = create_alphabetic_client_mapping(clients_27)
        @test mapping_27["Client_1"] == "A"
        @test mapping_27["Client_26"] == "Z"
        @test length(mapping_27["Client_27"]) == 2  # Should be double letter
        
        # Just test that it works for larger numbers, don't check exact values
        # (the exact mapping depends on the implementation)
        clients_52 = ["Client_$i" for i in 1:52]
        mapping_52 = create_alphabetic_client_mapping(clients_52)
        @test mapping_52["Client_1"] == "A"
        @test mapping_52["Client_26"] == "Z"
        @test length(mapping_52["Client_27"]) == 2  # Should be double letter
        
        # Test with 53 clients
        clients_53 = ["Client_$i" for i in 1:53]
        mapping_53 = create_alphabetic_client_mapping(clients_53)
        @test length(mapping_53["Client_53"]) == 2  # Should be double letter
        
        println("create_alphabetic_client_mapping: PASS")
    end
    
    @testset "scale_distribution" begin
        using DataFrames

        # Test normal case with non-zero demand
        clients = ["A", "B", "C"]
        df = DataFrame(
            A = [100.0, 200.0, 300.0],
            B = [50.0, 150.0, 250.0],
            C = [10.0, 20.0, 30.0]
        )

        distribution = Dict("A" => 100.0, "B" => 200.0, "C" => 300.0)

        scaled = scale_distribution(distribution, df, clients)

        # Check that scaling is correct
        @test isapprox(scaled["A"], 100.0 / sum(df[:, :A]); rtol=1e-10)
        @test isapprox(scaled["B"], 200.0 / sum(df[:, :B]); rtol=1e-10)
        @test isapprox(scaled["C"], 300.0 / sum(df[:, :C]); rtol=1e-10)

        println("scale_distribution (normal case): PASS")

        # Test edge case: zero-demand client
        clients_with_zero = ["A", "B", "Zero"]
        df_zero = DataFrame(
            A = [100.0, 200.0],
            B = [50.0, 150.0],
            Zero = [0.0, 0.0]
        )

        distribution_zero = Dict("A" => 100.0, "B" => 200.0, "Zero" => 300.0)

        scaled_zero = scale_distribution(distribution_zero, df_zero, clients_with_zero)

        # Zero-demand client should have Inf or NaN, but we just check it doesn't crash
        @test haskey(scaled_zero, "A")
        @test haskey(scaled_zero, "B")
        @test haskey(scaled_zero, "Zero")

        println("scale_distribution (zero-demand edge case): PASS")
    end

    # Note: plot_results, plot_cost_difference, plot_socialized_vs_individualized
    # are explicitly out of scope as they are rendering/IO-heavy
    @testset "Plotting functions - explicitly not tested" begin
        println("plot_results, plot_cost_difference, plot_socialized_vs_individualized: SKIPPED (rendering/IO-heavy)")
    end
end
