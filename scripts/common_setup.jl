# Shared includes and presets for the scripts/ and scripts/FigureScripts/ entry points.

# --- Project Modules ---
include("../src/Data_import.jl")
include("../src/Scenario_creation.jl")
include("../src/Imbalance_functions.jl")
include("../src/Game_theoretic_functions.jl")
include("../src/Plotting_functions.jl")
include("../src/Types.jl")
include("../src/Export_functions.jl")

# Named presets for which allocation mechanisms to calculate.
const ALLOCATION_PRESETS = Dict(
    :default => ["shapley", "MCC", "VCG", "gately_interval", "marginal_price", "flat_rate"],
    :all => ["shapley", "MCC", "MCC_budget_balanced", "VCG", "gately", "gately_interval", "marginal_price", "reduced_cost", "nucleolus", "flat_rate", "scaled"],
)

# Named presets for which clients to exclude from the analysis (client set is 22 total).
const CLIENT_EXCLUSION_PRESETS = Dict(
    :none => String[],                             # full 22-client portfolio
    :drop_smallest_2 => ["X", "W"],                 # 22 -> 20 clients
    :drop_smallest_3 => ["X", "W", "N"],             # 22 -> 19 clients
    :nucleolus_subset => ["F", "V", "J", "E", "T", "O", "Y"], # 22 -> 15 clients, small enough for nucleolus to remain tractable
)
