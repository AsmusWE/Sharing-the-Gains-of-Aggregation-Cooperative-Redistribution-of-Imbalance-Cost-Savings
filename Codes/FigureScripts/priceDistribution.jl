# This script simply plots the distribution of the imbalance spread

using Plots
using DataFrames
using Statistics
using StatsBase
using Dates

# Include the data import module
include("../Data_import.jl")

# Load the data
println("Loading data...")
systemData, clients, demand = load_data()

# Extract the combined data containing imbalance spread
priceData = systemData["price_prod_demand_df"]

# Filter data to only include dates before 2025
#priceData = filter(row -> 2024 <= year(row.HourUTC_datetime) < 2025, priceData)

# Extract imbalance spread values (removing any missing values)
imbalanceSpread = filter(!ismissing, priceData[!, :ImbalanceSpreadEUR])

println("Loaded $(length(imbalanceSpread)) imbalance spread observations")
println("Data range: $(minimum(imbalanceSpread)) to $(maximum(imbalanceSpread)) EUR/MWh")

# Calculate statistics
mean_spread = mean(imbalanceSpread)
median_spread = median(imbalanceSpread)
std_spread = std(imbalanceSpread)

println("\nStatistics:")
println("Mean: $(round(mean_spread, digits=2)) EUR/MWh")
println("Median: $(round(median_spread, digits=2)) EUR/MWh")
println("Std Dev: $(round(std_spread, digits=2)) EUR/MWh")

# Create histogram
p1 = histogram(imbalanceSpread, 
              bins=50,
              alpha=0.7,
              color=:steelblue,
              xlabel="Imbalance Spread (EUR/MWh)",
              ylabel="Frequency",
              #yscale=:log10,
              title="Distribution of Imbalance Spread",
              legend=false,
              grid=true,
              gridwidth=1,
              gridcolor=:lightgray)

# Add vertical lines for mean and median
vline!(p1, [mean_spread], color=:red, linewidth=2, linestyle=:dash, label="Mean")
vline!(p1, [median_spread], color=:orange, linewidth=2, linestyle=:dot, label="Median")

# Display the plot
display(p1)

# Additional analysis - show quartiles and extremes
q25 = quantile(imbalanceSpread, 0.25)
q75 = quantile(imbalanceSpread, 0.75)
iqr = q75 - q25

println("\nAdditional Statistics:")
println("25th percentile: $(round(q25, digits=2)) EUR/MWh")
println("75th percentile: $(round(q75, digits=2)) EUR/MWh")
println("IQR: $(round(iqr, digits=2)) EUR/MWh")
println("Positive spread observations: $(count(x -> x > 0, imbalanceSpread)) ($(round(100*count(x -> x > 0, imbalanceSpread)/length(imbalanceSpread), digits=1))%)")
println("Negative spread observations: $(count(x -> x < 0, imbalanceSpread)) ($(round(100*count(x -> x < 0, imbalanceSpread)/length(imbalanceSpread), digits=1))%)")
println("Zero spread observations: $(count(x -> x == 0, imbalanceSpread)) ($(round(100*count(x -> x == 0, imbalanceSpread)/length(imbalanceSpread), digits=1))%)")
