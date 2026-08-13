# Tests for Types.jl

@testset "Types.jl" begin
    # Test SimplePlotData construction
    allocations = ["shapley", "MCC"]
    system_data = Dict("test" => "data")
    allocation_costs = Dict("shapley" => Dict("A" => 1.0, "B" => 2.0))
    coalition_costs = Dict(["A", "B"] => -10.0)
    coalition_imbalances = Dict(["A", "B"] => [1.0, 2.0])
    clients = ["A", "B"]
    start_hour = DateTime(2024, 1, 1)
    sim_days = 1

    plot_data = SimplePlotData(
        allocations,
        system_data,
        allocation_costs,
        coalition_costs,
        coalition_imbalances,
        clients,
        start_hour,
        sim_days
    )

    # Test field access
    @test plot_data.allocations == allocations
    @test plot_data.system_data == system_data
    @test plot_data.allocation_costs == allocation_costs
    @test plot_data.coalition_costs == coalition_costs
    @test plot_data.coalition_imbalances == coalition_imbalances
    @test plot_data.clients == clients
    @test plot_data.start_hour == start_hour
    @test plot_data.sim_days == sim_days

    println("SimplePlotData construction and field access: PASS")
end
