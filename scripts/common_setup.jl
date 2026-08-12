# Shared includes and presets for the scripts/ and scripts/FigureScripts/ entry points.

# --- Project Modules ---
include("../src/Data_import.jl")
include("../src/Scenario_creation.jl")
include("../src/Imbalance_functions.jl")
include("../src/Game_theoretic_functions.jl")
include("../src/Plotting_functions.jl")
include("../src/Types.jl")

# Named presets for which allocation mechanisms to calculate.
const ALLOCATION_PRESETS = Dict(
    :default => ["shapley", "VCG", "gately_interval", "full_cost", "flat_rate"],
    :all => ["shapley", "VCG", "VCG_budget_balanced", "gately", "gately_interval", "full_cost", "reduced_cost", "nucleolus", "flat_rate", "scaled"],
)

# Named presets for which clients to exclude from the analysis (client set is 22 total).
const CLIENT_EXCLUSION_PRESETS = Dict(
    :none => String[],                             # full 22-client portfolio
    :drop_smallest_2 => ["X", "W"],                 # 22 -> 20 clients
    :drop_smallest_3 => ["X", "W", "N"],             # 22 -> 19 clients
    :nucleolus_subset => ["F", "V", "J", "E", "T", "O", "Y"], # 22 -> 15 clients, small enough for nucleolus to remain tractable
)
