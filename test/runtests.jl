# Entry point for running all tests
# Run with: julia --project=. test/runtests.jl

using Test

# Include test helpers (which includes all src files)
include("test_helpers.jl")

# Include all test files
const TEST_FILES = [
    "test_types.jl",
    "test_data_import.jl",
    "test_scenario_creation.jl",
    "test_imbalance_functions.jl",
    "test_game_theoretic_functions.jl",
    "test_plotting_functions.jl"
]

println("Running tests...")
println("="^60)

for test_file in TEST_FILES
    println("\nTesting $test_file...")
    try
        include(test_file)
    catch e
        println("ERROR in $test_file:")
        showerror(stderr, e)
        rethrow(e)
    end
end

println("\n" * "="^60)
println("All test files completed!")
