include("../Data_import.jl")
include("../imbalance_functions.jl")
using Plots

systemData, clients, demandData = load_data()
start_hour = DateTime(2024, 01, 01, 00, 0, 0)
sim_days = 366
systemData = set_period!(systemData, start_hour, sim_days)

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


pairs = sort(collect(clientTotalDemand), by = x->x[2], rev = true)
clients_sorted = [p[1] for p in pairs]
demand_values = [p[2] for p in pairs]
pv_values = [clientPVCoverage[client] * 100 for client in clients_sorted]  # Convert to percentage

# Create plot with two y-axes
x_positions = 1:length(clients_sorted)
plt = bar(x_positions, demand_values;
    legend = :topleft,
    label = "Total Demand (MWh)",
    xlabel = "Client",
    ylabel = "Total Demand (MWh)",
    title = "Client PV Coverage and Total Demand",
    xticks = (x_positions, clients_sorted),
    xrotation = 45,
    size = (750, 350),
    color = :orange,
    alpha = 0.5,
    bottom_margin = 8Plots.mm,
    left_margin = 5Plots.mm,
    right_margin = 8Plots.mm,
    top_margin = 3Plots.mm,
    background_color_legend = :white,
    legend_border = :black
)

# Add dummy series for PV coverage legend entry (invisible, just for legend)
bar!(plt, [NaN], [NaN]; 
    label = "PV Coverage",
    color = :steelblue,
    alpha = 0.7
)

# Add second y-axis for PV coverage
plt2 = twinx(plt)
bar!(plt2, x_positions, pv_values;
    legend = false,
    ylabel = "PV Coverage (%)",
    color = :steelblue,
    alpha = 0.7
)

display(plt)
