include("../common_setup.jl")
using Plots

system_data, clients, _ = load_data()
start_hour = DateTime(2024, 01, 01, 00, 0, 0)
sim_days = 366
system_data = set_period(system_data, start_hour, sim_days)

# Rename clients alphabetically based on total demand (highest to lowest).
# Drops the 2 smallest clients (by total demand) since they are excluded from this plot.
sorted_original_clients = sort_clients_by_demand(system_data, clients)[1:end-2]
# Create mapping from old names to new alphabetical names (A, B, C, ...)
client_name_mapping = create_alphabetic_client_mapping(sorted_original_clients)

# First, rename all columns to temporary names to avoid conflicts
temp_mapping = Dict(old_name => "TEMP_$(i)" for (i, old_name) in enumerate(sorted_original_clients))
for (old_name, temp_name) in temp_mapping
    rename!(system_data["price_prod_demand_df"], Symbol(old_name) => Symbol(temp_name))
end

# Then rename from temporary names to final alphabetical names
for (i, old_name) in enumerate(sorted_original_clients)
    temp_name = temp_mapping[old_name]
    new_name = client_name_mapping[old_name]
    rename!(system_data["price_prod_demand_df"], Symbol(temp_name) => Symbol(new_name))
end

# Update client_pv_ownership with new names
new_client_pv_ownership = Dict(client_name_mapping[old_name] => ownership
                             for (old_name, ownership) in system_data["client_pv_ownership"]
                             if haskey(client_name_mapping, old_name))
system_data["client_pv_ownership"] = new_client_pv_ownership

# Update clients list with alphabetical names
clients = [client_name_mapping[client] for client in sorted_original_clients]

total_solar_prod = system_data["price_prod_demand_df"][!, :SolarMWh]
client_pv_ownership = system_data["client_pv_ownership"]

client_pv_coverage = Dict{String, Float64}()
client_total_demand = Dict{String, Float64}()

for client in clients
    client_pv = sum(total_solar_prod .* client_pv_ownership[client])
    client_demand = sum(system_data["price_prod_demand_df"][!, Symbol(client)])
    client_pv_coverage[client] = client_pv / client_demand
    client_total_demand[client] = client_demand
end

# Clients are already sorted alphabetically A, B, C... (which corresponds to demand high to low)
clients_sorted = clients
demand_values = [client_total_demand[client] for client in clients_sorted]
pv_values = [client_pv_coverage[client] * 100 for client in clients_sorted]  # Convert to percentage

# Create plot with two y-axes
x_positions = 1:length(clients_sorted)
plt = bar(x_positions, demand_values;
    legend = (0.2, 0.95),
    label = "Demand [MWh]",
    xlabel = "Client",
    ylabel = "Demand [MWh]",
    #title = "Client PV Coverage and Total Demand",
    xticks = (x_positions, clients_sorted),
    xrotation = 45,
    color = PALETTE_LIGHT_GREEN,
    alpha = 1,
    #bottom_margin = 8Plots.mm,
    #left_margin = 5Plots.mm,
    #right_margin = 8Plots.mm,
    #top_margin = 3Plots.mm,
    background_color_legend = :white,
    legend_border = :black,
    legendfont = font(6, "Times Roman"),
    SMALL_FIGURE_STYLE...,
)

# Add dummy series for PV coverage legend entry (invisible, just for legend)
bar!(plt, [NaN], [NaN];
    label = "PV Coverage",
    color = PALETTE_ORANGE,
    alpha = 0.7
)

# Add second y-axis for PV coverage
plt2 = twinx(plt)
bar!(plt2, x_positions, pv_values;
    legend = false,
    ylabel = "PV Coverage [%]",
    color = PALETTE_ORANGE,
    alpha = 0.7,
    guidefontsize = 8,
    tickfontsize = 6
)

display(plt)
