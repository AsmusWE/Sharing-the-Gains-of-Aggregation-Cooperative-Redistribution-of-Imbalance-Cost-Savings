# Control and Revenue Distribution of Shared Hybrid PV and Battery Systems

This repository contains Julia scripts for simulating, analyzing, and visualizing the risk distribution for a balancing responsible party with a portfolio that owns a shared PV system. The project uses cooperative game theory to allocate costs and revenues among participants, focusing on imbalance management and risk assessment through Conditional Value-at-Risk (CVaR) optimization.

The implementation is based on a case study, and as such the data is not publicly available. Scripts will therefore not run without the proper data files.

## Repository Structure

### Core Scripts
- **Imbalance_main.jl**: Main script for running imbalance analysis, allocation calculations, and stability checks.
- **Data_import.jl**: Handles data loading and preprocessing from various sources, including demand data, PV production, price data, and forecasts with 15-minute resolution support.
- **Scenario_creation.jl**: Generates scenarios for clients based on historical data and weekdays.
- **Imbalance_functions.jl**: Contains functions related to calculating imbalances, costs and CVaR
- **Game_theoretic_functions.jl**: Implements cooperative game theory allocation methods including Shapley value, VCG, Gately point, nucleolus, and uniform price allocations.
- **Plotting_functions.jl**: Functions for visualizing allocation results, client costs, and demand/production statistics.

### Analysis and Visualization Scripts
- **Plotting_main.jl**: Main plotting script that loads serialized results and generates visualizations for different allocation methods and scenarios.
- **Timing_script.jl**: Performance analysis script for measuring computational time of different allocation methods with varying coalition sizes.

### Thesis Figure Generation
- **ThesisFigureScripts/**: Directory containing specialized scripts for generating figures. These are independent from the rest of the repo:
  - **DataAvailabilityPlot.jl**: Generates plots showing data availability and missing data patterns for the case study dataset.
  - **Gains_Of_Aggregation.jl**: Analyzes and visualizes the gains from aggregation for different coalition sizes and allocation methods.
  - **IntroPlot.py**: Python script for generating introductory plots comparing cost distributions under different pricing mechanisms.

### Data Storage
- **Data/**: Contains input data files:
  - Core data files: `consumption_data.csv` (not included due to NDA), `ImbalancePrice.csv`, `ProductionMunicipalityHour.csv`, `Solar_Forecasts_Hour.csv`
  - Asset information: `Asset_master_data_asmus.csv` and `.xlsx` (not included due to NDA)
  - Serialized scenario data: `all_scenarios.jls`, `variance_plot_data_scenarios.jls`
  - Documentation: `Data-sources.txt`
- **Results/**: Contains simulation outputs, serialized results, and generated plots:
  - Allocation results for different forecast combinations (e.g., `all_perfectPV.jls`, `all_scenPV_scenDemand.jls`)
  - CVaR optimization results: `CVaR_*.jls` files (Not included due to NDA)
  - Timing analysis: `timing_*.svg` plots
  - Various intermediate results and temporary files

## Key Features

### Allocation Methods
- **Shapley Value**: Fair allocation based on marginal contributions across all possible coalitions
- **VCG Mechanism**: Incentive-compatible mechanism with optional budget balancing (VCG_BB)
- **Gately Point**: Proportional allocation based on propensity to disrupt, with daily and 15-minute interval variants
- **Nucleolus**: Lexicographically minimal excess solution for coalition stability
- **Cost-Based Allocation**: Uniform pricing mechanism for CVaR problem
- **Full Cost Transfer**: Uniform pricing mechanism for cost problem
- **Reduced Cost**: Alternative simple mechanism, only for cost problem

### Forecasting Capabilities
- **Perfect Forecasts**: Ideal scenario with exact future knowledge
- **Scenario-Based Forecasting**: Rolling scenario generation using historical patterns for demand and PV production
- **Noise-Based Forecasting**: Stochastic forecasting with configurable standard deviations

### Risk Assessment
- **CVaR Optimization**: Conditional Value-at-Risk minimization for portfolio risk management
- **Coalition Stability Analysis**: Excess calculation and stability checks for proposed allocations
- **Variance Analysis**: Statistical analysis of allocation performance across different scenarios

## How to Run

1. **Install Julia** (version 1.6 or later) and required packages:
   ```julia
   using Pkg
   Pkg.add([
       "JuMP", "HiGHS", "Gurobi",           # Optimization
       "Plots", "StatsPlots",               # Visualization  
       "Combinatorics",                     # Coalition enumeration
       "CSV", "DataFrames",                 # Data handling
       "Dates", "TimeZones",                # Time series processing
       "Serialization", "Statistics",       # Data storage and analysis
       "Random", "LsqFit"                   # Stochastic analysis and fitting
   ])
   ```

2. **Prepare Data**: Place the required data files in the `Data/` directory:
   - `Asset_master_data_asmus.csv`: Client and asset information including PV ownership shares
   - `consumption_data.csv`: Client consumption data 
   - `ImbalancePrice.csv`: Imbalance and spot price data
   - `ProductionMunicipalityHour.csv`: Hourly PV production data
   - `Solar_Forecasts_Hour.csv`: Solar production forecasts

3. **Configure Simulation**: Edit parameters in `Imbalance_main.jl`:
   - **Calculation Types**: Set boolean flags for which analyses to run:
     ```julia
     CVaRFull = false        # CVaR calculation with all coalitions (computationally intensive)
     CVaRSimple = true       # CVaR calculation with simple coalitions (recommended for testing)
     costSimple = false      # Cost-only simple allocation
     costFull = false        # Cost calculation for all coalitions
     dailyPlot = false       # Daily variance analysis
     ```
   - **Allocation Methods**: Select which allocation mechanisms to include:
     ```julia
     allocations = [
         "VCG",                    # Standard VCG mechanism
         "VCG_budget_balanced",    # Budget-balanced VCG variant
         "gately",                 # Gately point allocation
         "gately_interval",        # Gately point (15-minute intervals)
         "full_cost",              # Uniform pricing for cost
         "reduced_cost",           # Alternative simple mechanism
         "flat_rate"               # Flat rate allocation
     ]
     ```
   - **Simulation Period**: Configure time period and scenarios:
     ```julia
     start_hour = DateTime(2025, 4, 04, 00, 0, 0)  # Simulation start date
     num_scenarios_demand = 5     # Number of demand scenarios
     num_scenarios_price = 1      # Number of price scenarios
     alphaCVaR = 0.05            # CVaR confidence level (5%)
     ```
   - **Forecasting Configuration**: Set forecast types and noise levels:
     ```julia
     stochasticData = Dict(
         "pv_forecast" => "scenarios",      # Options: "perfect", "scenarios"
         "demand_forecast" => "scenarios",  # Options: "perfect", "scenarios", "noise"
         "demand_noise_std" => 0.28        # Standard deviation for noise forecasting
     )
     ```

4. **Run Analysis**: Execute the main script:
   ```julia
   julia Imbalance_main.jl
   ```

5. **Generate Plots**: After running the main analysis, use plotting scripts:
   ```julia
   julia Plotting_main.jl    # For allocation result visualization
   julia Timing_script.jl    # For performance analysis
   ```

## Customization

### Allocation Methods
Modify the `allocations` array in `Imbalance_main.jl` to include/exclude specific allocation methods:
- `"shapley"`: Shapley value calculation
- `"VCG"`: Standard VCG mechanism  
- `"VCG_budget_balanced"`: Budget-balanced VCG variant
- `"gately"`: Gately point 
- `"gately_interval"`: Gately point (15-minute intervals)
- `"nucleolus"`: Nucleolus solution
- `"cost_based"`: CVaR-based uniform pricing
- `"full_cost"`: Uniform pricing mechanism for cost
- `"reduced_cost"`: Alternative simple mechanism for cost

### Forecasting Parameters
- **Demand Forecast**: Set `demand_noise_std` (default: 0.17 for 7-10% MAE)
- **PV Forecast**: Set `pv_noise_std` (default: 0.32 for 22.5-25% MAE)  
- **Scenario Generation**: Configure `num_scenarios` and modify rolling window parameters in `Scenario_creation.jl`
- **Forecast Combinations**: Mix perfect/scenario/noise forecasting for demand and PV independently

### Client and Coalition Configuration
- **Client Filtering**: Modify client lists in main scripts to focus on specific participants or reduce coalition sizes
- **CVaR Parameters**: Adjust `alpha` confidence level for risk assessment
- **Simulation Period**: Configure `start_hour` and `sim_days` for different analysis periods

### Performance Optimization
- **Solver Selection**: Choose between HiGHS (open-source) and Gurobi (commercial) for optimization

## Dependencies

### Core Julia Packages
- **JuMP**: Mathematical optimization modeling framework
- **HiGHS**: High-performance open-source linear programming solver
- **Gurobi**: Commercial optimization solver (optional, requires license)
- **Combinatorics**: Coalition enumeration and combinatorial analysis
- **CSV, DataFrames**: Data handling and manipulation
- **Dates, TimeZones**: Time series processing and temporal data management
- **Serialization**: Result storage and retrieval
- **Statistics**: Statistical analysis and risk metrics

### Visualization and Analysis
- **Plots, StatsPlots**: Julia plotting ecosystem for internal visualization
- **Random**: Stochastic simulation and reproducibility
- **LsqFit**: Curve fitting for performance analysis (used in timing scripts)

### Optional and Alternative Tools
- **Python Integration**: For advanced plotting and data analysis
  - **matplotlib**: Publication-quality figure generation
  - **numpy, scipy**: Scientific computing (for IntroPlot.py)

## Output and Results

The project generates various types of output:

### Serialized Results (.jls files)
- **Allocation Results**: Complete allocation data for different forecast scenarios
- **CVaR Results**: Risk-optimized allocation results
- **Timing Data**: Performance benchmarks for different methods
- **Variance Analysis**: Statistical analysis of allocation performance

### Visualizations
- **Allocation Comparison Plots**: Side-by-side comparison of different allocation methods
- **Cost Distribution Analysis**: Client-specific cost breakdowns and comparisons
- **Data Quality Plots**: Missing data patterns and inconsistency analyses
- **Performance Plots**: Computational time analysis for scalability assessment

### Data Exports
- **CSV Files**: Structured data exports for further analysis
- **SVG Plots**: Scalable vector graphics for publication use

## Performance Considerations

- **Coalition Size**: Computational complexity grows exponentially with the number of participants
- **Nucleolus Calculation**: Most computationally intensive method, suitable for smaller coalitions (≤12 clients)
- **Shapley Value**: Moderate computational cost, feasible for medium-sized coalitions (≤19 clients)
- **Memory Usage**: Large simulations benefit from periodic garbage collection
- **Solver Choice**: Gurobi typically faster than HiGHS for complex optimization problems

## Contact

For questions or contributions, please contact the repository owner.
