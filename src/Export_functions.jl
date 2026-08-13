using Parquet2, JSON, DataFrames, Dates

# Writes the pieces of a SimplePlotData (see Types.jl) to plain Parquet/JSON files so they
# can be read from Python without needing a Julia Serialization-compatible reader.
#
# Layout written under `out_dir`:
#   price_prod_demand.parquet   - system_data["price_prod_demand_df"]
#   client_pv_ownership.json    - system_data["client_pv_ownership"]
#   allocation_costs.json       - alloc name -> {client -> cost}
#   coalition_costs.json        - coalition_key(coalition) -> cost
#   coalition_imbalances.json   - coalition_key(coalition) -> [imbalance...]
#   meta.json                   - clients, allocations, start_hour (ISO string), sim_days

# Canonical string form of a coalition (a Vector{String} of client ids), used as a JSON
# object key since JSON objects require string keys. Clients are sorted so the same
# coalition always maps to the same key regardless of the order it was built in; Python
# must sort+join the same way (",".join(sorted(coalition))) to look up a coalition.
coalition_key(coalition) = join(sort(String.(coalition)), ",")

function write_json(path, data)
    write(path, JSON.json(data))
end

function export_price_prod_demand(price_prod_demand_df::DataFrame, out_dir)
    Parquet2.writefile(joinpath(out_dir, "price_prod_demand.parquet"), price_prod_demand_df)
end

function export_client_pv_ownership(client_pv_ownership, out_dir)
    write_json(joinpath(out_dir, "client_pv_ownership.json"), client_pv_ownership)
end

"""
    export_plot_data(plot_data::SimplePlotData, out_dir)

Export every field of a SimplePlotData needed for plotting to Parquet/JSON files under
`out_dir`. `out_dir` is created if it doesn't exist.
"""
function export_plot_data(plot_data, out_dir)
    mkpath(out_dir)

    export_price_prod_demand(plot_data.system_data["price_prod_demand_df"], out_dir)
    export_client_pv_ownership(plot_data.system_data["client_pv_ownership"], out_dir)

    write_json(joinpath(out_dir, "allocation_costs.json"), plot_data.allocation_costs)

    coalition_costs_out = Dict(coalition_key(c) => v for (c, v) in plot_data.coalition_costs)
    write_json(joinpath(out_dir, "coalition_costs.json"), coalition_costs_out)

    coalition_imbalances_out = Dict(coalition_key(c) => v for (c, v) in plot_data.coalition_imbalances)
    write_json(joinpath(out_dir, "coalition_imbalances.json"), coalition_imbalances_out)

    write_json(joinpath(out_dir, "meta.json"), Dict(
        "clients" => plot_data.clients,
        "allocations" => plot_data.allocations,
        "start_hour" => string(plot_data.start_hour),
        "sim_days" => plot_data.sim_days,
    ))

    return out_dir
end

"""
    export_system_data(system_data::Dict{String,Any}, out_dir)

Export the raw `system_data` dict returned by `load_data()` (i.e. not tied to a specific
cached simulation run) to Parquet/JSON files under `out_dir`.
"""
function export_system_data(system_data, out_dir)
    mkpath(out_dir)
    export_price_prod_demand(system_data["price_prod_demand_df"], out_dir)
    export_client_pv_ownership(system_data["client_pv_ownership"], out_dir)
    return out_dir
end
