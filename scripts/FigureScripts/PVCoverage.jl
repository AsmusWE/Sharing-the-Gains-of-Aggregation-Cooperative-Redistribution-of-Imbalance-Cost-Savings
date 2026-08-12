include("../../src/Data_import.jl")
include("../../src/Imbalance_functions.jl")
using Plots

systemData, clients, demandData = load_data()
start_hour = DateTime(2024, 01, 01, 00, 0, 0)
sim_days = 366
systemData = set_period!(systemData, start_hour, sim_days)

# Rename clients alphabetically based on total demand (highest to lowest)
total_demands = Dict(client => sum(systemData["price_prod_demand_df"][!, Symbol(client)]) for client in clients)
sorted_clients_pairs = sort(collect(total_demands), by = x -> -x[2])
sorted_original_clients = [client for (client, _) in sorted_clients_pairs]
sorted_original_clients = sorted_original_clients[1:end-2] 
# Create mapping from old names to new alphabetical names (A, B, C, ...)
alphabet = ['A':'Z'...]
client_name_mapping = Dict(old_name => string(alphabet[i]) for (i, old_name) in enumerate(sorted_original_clients))

# First, rename all columns to temporary names to avoid conflicts
temp_mapping = Dict(old_name => "TEMP_$(i)" for (i, old_name) in enumerate(sorted_original_clients))
for (old_name, temp_name) in temp_mapping
    rename!(systemData["price_prod_demand_df"], Symbol(old_name) => Symbol(temp_name))
end

# Then rename from temporary names to final alphabetical names
for (i, old_name) in enumerate(sorted_original_clients)
    temp_name = temp_mapping[old_name]
    new_name = client_name_mapping[old_name]
    rename!(systemData["price_prod_demand_df"], Symbol(temp_name) => Symbol(new_name))
end

# Update clientPVOwnership with new names
new_clientPVOwnership = Dict(client_name_mapping[old_name] => ownership 
                             for (old_name, ownership) in systemData["clientPVOwnership"] 
                             if haskey(client_name_mapping, old_name))
systemData["clientPVOwnership"] = new_clientPVOwnership

# Update clients list with alphabetical names
clients = [client_name_mapping[client] for client in sorted_original_clients]

totalSolarProd = systemData["price_prod_demand_df"][!, :SolarMWh]
clientPVOwnership = systemData["clientPVOwnership"]

clientPVCoverage = Dict{String, Float64}()
clientTotalDemand = Dict{String, Float64}()

for client in clients
    clientPV = sum(totalSolarProd .* clientPVOwnership[client])
    clientDemand = sum(systemData["price_prod_demand_df"][!, Symbol(client)])
    clientPVCoverage[client] = clientPV / clientDemand
    clientTotalDemand[client] = clientDemand
end

# Clients are already sorted alphabetically A, B, C... (which corresponds to demand high to low)
clients_sorted = clients
demand_values = [clientTotalDemand[client] for client in clients_sorted]
pv_values = [clientPVCoverage[client] * 100 for client in clients_sorted]  # Convert to percentage

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
    size = (320, 120),
    color = RGB(150/255, 206/255, 180/255),  # #96ceb4
    alpha = 1,
    #bottom_margin = 8Plots.mm,
    #left_margin = 5Plots.mm,
    #right_margin = 8Plots.mm,
    #top_margin = 3Plots.mm,
    background_color_legend = :white,
    legend_border = :black,
    guidefont = (8, "Times Roman"),
    tickfont = (6, "Times Roman"),
    legendfont = (6, "Times Roman"),
)

# Add dummy series for PV coverage legend entry (invisible, just for legend)
bar!(plt, [NaN], [NaN]; 
    label = "PV Coverage",
    color = RGB(255/255, 204/255, 92/255),  # #ffcc5c
    alpha = 0.7
)

# Add second y-axis for PV coverage
plt2 = twinx(plt)
bar!(plt2, x_positions, pv_values;
    legend = false,
    ylabel = "PV Coverage [%]",
    color = RGB(255/255, 204/255, 92/255),  # #ffcc5c
    alpha = 0.7,
    guidefontsize = 8,
    tickfontsize = 6
)

display(plt)
