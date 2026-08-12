# Sharing the Gains of Aggregation

Code accompanying Asmus Winther Eriksen's DTU master's thesis, *"Sharing the Gains of Aggregation: Cooperative Redistribution of Imbalance Cost Savings"*. The full report is in [`docs/`](docs/).

## Abstract

As renewable penetration increases, Balance Responsible Parties (BRPs) face growing uncertainty in matching supply and demand. While portfolio aggregation measurably reduces both imbalance costs and risk, it also obscures each consumer or producer's true contribution, particularly as TSOs in the Nordic countries move towards partially asymmetric pricing in the full-cost balancing imbalance settlement scheme.

This thesis develops a cooperative game-theoretic framework to allocate ex-post imbalance costs among prosumers in a 22-client portfolio. Only the day-ahead and imbalance markets are considered, and an asymmetric two-price imbalance settlement is used to approximate full-cost balancing. Cost allocation is modeled as a transferable-utility game. Multiple core-selection mechanisms are implemented: the Shapley Value, VCG, the Gately Point, Nucleolus, and two bespoke mechanisms: Uniform Price and Reduced Cost. These are compared against a flat rate allocation where the BRP makes no effort to differentiate between clients.

Each mechanism is assessed for its computational tractability, fairness, budget balance, and incentive compatibility. The Shapley Value and Nucleolus are found impractical for these problems, as they are too computationally taxing to scale for large portfolios. Likewise, VCG is impractical because of its lack of budget balance. A modified VCG mechanism that ensures budget balance for this problem is proposed; however, it results in unstable allocations for some games.

Among the classical core selection mechanisms, the Gately Point proves to be the only practical mechanism, based on computational complexity, stability, and budget balance. The Reduced Cost and Uniform Price mechanisms prove practical and fair, and can be considered as simpler alternatives to the Gately Point.

While several tested mechanisms yield stable allocations, each inherently favors certain types of clients. In some cases, a client's allocated cost may more than double when transitioning from a mechanism that benefits them to one that does not. As forecast accuracy improves, these disparities become more pronounced, making it increasingly important to understand which clients are advantaged or disadvantaged by a given mechanism.

The application of cooperative game theory to BRP pricing is found to be an important consideration, as there are significant differences in cost between clients in the portfolio. Providing similar rates for all clients distributes costs unfairly and does not reward clients for having low imbalances. Therefore, cooperative game theory can aid prosumers by assigning costs that reflect their balancing needs, and aid BRPs and the electrical grid by incentivizing prosumers to work towards predictable consumption.

## Repository structure

```
├── src/                      # Core library functions
│   ├── Data_import.jl        # Load and preprocess demand/PV/price data
│   ├── Scenario_creation.jl  # Demand and imbalance-spread scenario generation
│   ├── Imbalance_functions.jl        # Bid optimization and cost/imbalance calculation
│   ├── Game_theoretic_functions.jl   # Allocation mechanisms (Shapley, VCG, Gately, ...)
│   ├── Plotting_functions.jl # Result visualization
│   └── Types.jl              # Shared data structures
├── scripts/                  # Entry-point scripts
│   ├── common_setup.jl       # Shared includes and named presets
│   ├── Imbalance_main.jl     # Run cost/allocation calculations, serializes results
│   ├── Plotting_main.jl      # Load serialized results and generate plots
│   └── FigureScripts/        # Standalone thesis-figure scripts
├── data/
│   ├── public/                # Tracked EnergiDataService CSVs
│   ├── private/                # Gitignored NDA data (not included in this repo)
│   └── sources.txt
├── results/
│   ├── figures/               # Tracked example output
│   └── cache/                 # Gitignored serialized run outputs (.jls)
└── docs/                      # Thesis report
```

## Getting started

1. Install [Julia](https://julialang.org/) (developed against 1.11).
2. From the repository root, instantiate the environment:
   ```julia
   using Pkg
   Pkg.instantiate()
   ```
3. Run the main analysis, then generate plots from its output:
   ```
   julia --project=. scripts/Imbalance_main.jl
   julia --project=. scripts/Plotting_main.jl
   ```

## Data availability

The public EnergiDataService inputs (spot prices, imbalance prices, regional production, solar forecasts) are included under [`data/public/`](data/public/) — see [`data/sources.txt`](data/sources.txt) for exact sources. The client consumption and PV-ownership data (`data/private/`) is covered by an NDA with the case-study partner and is **not included** in this repository; the code will not run end-to-end without it.

## Solver

Optimization uses [HiGHS](https://highs.dev/), an open-source solver — no commercial license is required. `Pkg.instantiate()` is the only setup step.

## Allocation methods

Implemented in `src/Game_theoretic_functions.jl` and selectable via the `allocations` list in `scripts/Imbalance_main.jl` (see `ALLOCATION_PRESETS` in `scripts/common_setup.jl` for named presets):

- `shapley` — Shapley value
- `VCG` — Vickrey–Clarke–Groves mechanism
- `VCG_budget_balanced` — budget-balanced VCG variant
- `gately` / `gately_interval` — Gately point (single value / 15-minute interval)
- `nucleolus` — lexicographically minimal-excess solution
- `full_cost` — uniform marginal-price allocation
- `reduced_cost` — asymmetric-price allocation
- `flat_rate` — no differentiation between clients (baseline)
- `scaled` — scaled allocation

The default preset (`ALLOCATION_PRESETS[:default]`) is `["shapley", "VCG", "gately_interval", "full_cost", "flat_rate"]`; `nucleolus` and `shapley` become computationally intractable above roughly 12 and 19 clients respectively, since both require evaluating every coalition.
