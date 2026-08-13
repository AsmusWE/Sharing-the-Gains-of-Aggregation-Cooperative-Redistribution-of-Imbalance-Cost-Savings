using Dates

# Shared plotting-data container, populated by Imbalance_main.jl and consumed by
# Plotting_main.jl / FigureScripts. Kept in one place so the struct shape can't
# silently drift between independently-declared copies.
# Guarded so this file can be `include`d again in an already-running REPL/test
# session (e.g. re-running test/runtests.jl) without hitting Julia's "invalid
# redefinition of constant" error on the struct.
if !@isdefined(SimplePlotData)
    struct SimplePlotData
        allocations::Vector{String}
        system_data::Dict{String, Any}
        allocation_costs::Dict{String, Any}
        coalition_costs::Dict{Any, Any}
        coalition_imbalances::Dict{Any, Any}
        clients::Vector{String}
        start_hour::DateTime
        sim_days::Int
    end
end
