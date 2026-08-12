# Tests for Types.jl

@testset "Types.jl" begin
    # Test SimplePlotData construction
    allocations = ["shapley", "MCC"]
    systemData = Dict("test" => "data")
    allocationCosts = Dict("shapley" => Dict("A" => 1.0, "B" => 2.0))
    coalitionCosts = Dict(["A", "B"] => -10.0)
    imbalancesDict = Dict(["A", "B"] => [1.0, 2.0])
    clients = ["A", "B"]
    start_hour = DateTime(2024, 1, 1)
    sim_days = 1
    
    plot_data = SimplePlotData(
        allocations,
        systemData,
        allocationCosts,
        coalitionCosts,
        imbalancesDict,
        clients,
        start_hour,
        sim_days
    )
    
    # Test field access
    @test plot_data.allocations == allocations
    @test plot_data.systemData == systemData
    @test plot_data.allocationCosts == allocationCosts
    @test plot_data.coalitionCosts == coalitionCosts
    @test plot_data.imbalancesDict == imbalancesDict
    @test plot_data.clients == clients
    @test plot_data.start_hour == start_hour
    @test plot_data.sim_days == sim_days
    
    println("SimplePlotData construction and field access: PASS")
end
