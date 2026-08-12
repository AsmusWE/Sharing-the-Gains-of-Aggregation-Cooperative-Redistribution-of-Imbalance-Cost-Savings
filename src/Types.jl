using Dates

# Shared plotting-data container, populated by Imbalance_main.jl and consumed by
# Plotting_main.jl / FigureScripts. Kept in one place so the struct shape can't
# silently drift between independently-declared copies.
struct SimplePlotData
    allocations::Vector{String}
    systemData::Dict{String, Any}
    allocationCosts::Dict{String, Any}
    coalitionCosts::Dict{Any, Any}
    imbalancesDict::Dict{Any, Any}
    clients::Vector{String}
    start_hour::DateTime
    sim_days::Int
end
