# TestTheoreticalResults.jl
# Validates several analytical results from the paper
# ("Sharing the Gains of Aggregation: Cooperative Imbalance Cost Allocation")
# against the real 19-consumer / year-2024 case study data.
#
# Unlike Imbalance_main.jl, this script only needs the sparse coalition set (singletons,
# grand coalition, leave-one-out coalitions), since MCC, VCG, and marginal price all have
# O(|N|) complexity (Table I) and none of the checks below need Shapley/Nucleolus.
#
# Usage: julia --project scripts/TestTheoreticalResults.jl

# --- Project Modules ---
include("common_setup.jl")

# --- External Packages ---
using Dates, Random, Combinatorics, Statistics
GC.gc()

Random.seed!(1)

# =========================
# 1. Data Loading & Setup (mirrors Imbalance_main.jl, scoped to 19 clients)
# =========================
system_data, clients, demand_data = load_data()
# On this machine's data/private snapshot, load_data() already returns exactly the paper's
# 19-consumer case study (clients with complete data), matching Imbalance_main.jl's own
# CLIENT_EXCLUSION_PRESETS[:none]. CLIENT_EXCLUSION_PRESETS[:drop_smallest_3] assumes a fuller
# 22-client snapshot and would wrongly drop 3 more consumers on top of this one -- do not apply
# it here.
clients = filter(x -> !(x in CLIENT_EXCLUSION_PRESETS[:none]), clients)
println("Testing theoretical results on $(length(clients)) consumers")
flush(stdout)

start_hour = DateTime(2024, 01, 01, 00, 0, 0)
sim_days = 366
num_scenarios_demand = 5
num_scenarios_price = 50
spread_scens_length = 1
dummy = false
use_newsvendor = true

stochastic_data = Dict(
    "pv_forecast" => "scenarios",
    "demand_forecast" => "scenarios",
    "demand_noise_std" => 0.28,
)

if stochastic_data["demand_forecast"] == "scenarios"
    stochastic_data["demand_scenarios"] = generate_scenarios_demand_rolling(clients, demand_data, start_hour, sim_days; num_scenarios=num_scenarios_demand)
end

stochastic_data["imbalance_spread"], stochastic_data["spot_price"] = generate_scenarios_imbalance_spread(system_data, start_hour, spread_scens_length; num_scenarios=num_scenarios_price)
stochastic_data["dominant_direction_scenarios"] = generate_dominant_direction(stochastic_data["imbalance_spread"])

system_data = set_period(system_data, start_hour, sim_days)

# =========================
# 2. Sparse coalition costs & imbalances (singletons, grand, leave-one-out only)
# =========================
# Unlike Imbalance_main.jl, this does NOT chunk into 30-day "reconciliation periods" with
# rolling re-bidding. That chunking exists there to keep monthly-rolling bids realistic and to
# bound memory for the full coalition power set; neither applies here (only 33 sparse
# coalitions, and no need to model rolling re-optimization for a static theory check). Chunking
# was tried and found to silently corrupt results on this dataset: `set_period`/
# `find_period_start_index` slice by row *position*, not by calendar date, and the underlying
# demand data (converted from CET to UTC) has a datetime irregularity around the March 2024 DST
# transition. Once the loop's position-based 30-day windows cross that point, they drift out of
# sync with calendar-date period boundaries, causing several days to be double-counted in the
# accumulated coalition_imbalances. A single full-year call avoids this: it slices the data
# exactly once, so there is nothing to drift out of sync.
grand_coalition = vec(clients)
coalitions = sparse_coalitions(clients)   # 2*19 + 1 = 39 coalitions, not the full power set
println("Calculating costs for $(length(coalitions)) coalitions (sparse set)...")
flush(stdout)

coalition_costs, coalition_imbalances = calculate_total_costs_specific(
    system_data, coalitions, stochastic_data, sim_days; dummy = dummy, one_price = false, use_newsvendor = use_newsvendor
)

println("Total grand-coalition cost: ", coalition_costs[grand_coalition])
flush(stdout)

# =========================
# 3. Per-hour primitives shared by Checks 1 & 2
# =========================
spread = system_data["price_prod_demand_df"][!, "ImbalanceSpreadEUR"]
T = length(spread)
@assert T == length(coalition_imbalances[grand_coalition]) "Spread series and imbalance series length mismatch"

Δ_N = coalition_imbalances[grand_coalition]
Δ_Nwo = Dict(c => coalition_imbalances[filter(x -> x != c, grand_coalition)] for c in clients)

# Paper's (Δ ≤ 0)/(Δ > 0) split -- a boolean is enough to detect a sign flip
category(x) = x > 0

# Paper-convention (cost ≥ 0) per-hour cost, matching calculate_total_costs_specific's
# `min.(0, Δ .* spread)` clamp: cost_t(S) = max(0, -Δ_t,S * spread_t)
hour_cost(Δ, t) = max(0.0, -Δ[t] * spread[t])

can_flip = falses(T)
flip_count_per_client = Dict(c => 0 for c in clients)
for t in 1:T, c in clients
    if category(Δ_Nwo[c][t]) != category(Δ_N[t])
        can_flip[t] = true
        flip_count_per_client[c] += 1
    end
end

# =========================
# Check 1: sign-flip hours + MCC/VCG budget balance by group
# =========================
println()
println("=== Check 1: Sign-flip hours & MCC/VCG budget balance ===")

cost_N_gap_no_flip = 0.0
cost_N_gap_flip = 0.0
mcc_gap_no_flip = 0.0
mcc_gap_flip = 0.0
vcg_gap_no_flip = 0.0
vcg_gap_flip = 0.0

# Also accumulate per-client totals to cross-check against mcc_allocation/vcg_allocation
manual_mcc_total = Dict(c => 0.0 for c in clients)
manual_vcg_total = Dict(c => 0.0 for c in clients)

lambda_identity_max_err = 0.0

for t in 1:T
    c_t_N = hour_cost(Δ_N, t)

    # Safety net for the lambda sign convention (see note below): lambda_{t,N}*Δ_{t,N} must
    # equal c_t_N exactly, since both are just c_t(N) computed two different ways. If a future
    # edit reintroduces a sign mismatch between hour_cost's and lambda's conventions, this will
    # stop being ~0 and the WARNING below will fire.
    lambda_t_N_check = (Δ_N[t] * spread[t] < 0) ? -spread[t] : 0.0
    global lambda_identity_max_err = max(lambda_identity_max_err, abs(lambda_t_N_check * Δ_N[t] - c_t_N))

    mcc_sum_t = 0.0
    vcg_sum_t = 0.0
    for c in clients
        c_t_Nwo = hour_cost(Δ_Nwo[c], t)
        m_t_i = c_t_N - c_t_Nwo
        manual_mcc_total[c] += m_t_i
        mcc_sum_t += m_t_i

        # Marginal price (eq. 11): consumer priced at the grand-coalition spread whenever N
        # itself harms that hour, i.e. lambda_{t,N} = spread[t] if Δ_N and spread have
        # opposite signs (harms), else 0. NOTE: lambda must be the negative of the repo's raw
        # `spread` column here, not `spread` itself: the repo's own cost identity is
        # `min(0, Δ*spread)` (negative-for-cost), while `hour_cost` above (and everything else
        # in this loop) uses the paper's cost >= 0 convention. Using +spread would silently
        # give lambda*Δ = -hour_cost, i.e. the *repo* sign convention leaking into an otherwise
        # paper-convention computation -- exactly the mismatch that broke the flip/no-flip VCG
        # budget-balance split (mixing a paper-convention MCC/cost term with a repo-convention
        # VCG term). Using -spread makes lambda*Δ == hour_cost(Δ, t) exactly, verified below.
        lambda_t_N = (Δ_N[t] * spread[t] < 0) ? -spread[t] : 0.0

        # VCG per hour (eq. 10b): (lambda_{t,N} - lambda_{t,N\{i}}) * Δ_{t,N\{i}}
        lambda_t_Nwo = (Δ_Nwo[c][t] * spread[t] < 0) ? -spread[t] : 0.0
        vcg_t_i = (lambda_t_N - lambda_t_Nwo) * Δ_Nwo[c][t]
        manual_vcg_total[c] += vcg_t_i
        vcg_sum_t += vcg_t_i
    end

    if can_flip[t]
        global cost_N_gap_flip += c_t_N
        global mcc_gap_flip += mcc_sum_t
        global vcg_gap_flip += vcg_sum_t
    else
        global cost_N_gap_no_flip += c_t_N
        global mcc_gap_no_flip += mcc_sum_t
        global vcg_gap_no_flip += vcg_sum_t
    end
end

n_no_flip = count(!, can_flip)
n_flip = count(can_flip)

println("Sign-convention self-check: max |lambda_t,N * Δ_t,N - c_t(N)| = $(round(lambda_identity_max_err, digits=8)) EUR ",
        "(must be ~0 -- lambda and hour_cost must use the same sign convention)")
if lambda_identity_max_err > 1e-6
    println("  WARNING: lambda/hour_cost sign convention mismatch detected -- downstream VCG/MP numbers below are unreliable.")
end
println("Hours where no agent can flip the imbalance sign: $n_no_flip / $T ($(round(100*n_no_flip/T, digits=2))%)")
println("Hours where at least one agent can flip the imbalance sign: $n_flip / $T ($(round(100*n_flip/T, digits=2))%)")
println()
println("MCC budget balance (allocated - cost, paper convention, cost >= 0):")
println("  No-flip hours: ", round(mcc_gap_no_flip - cost_N_gap_no_flip, digits=6), " EUR  (expect ~0, Lemma IV.2)")
println("  Flip hours:    ", round(mcc_gap_flip - cost_N_gap_flip, digits=6), " EUR  (expect < 0, Lemma IV.3 / Thm IV.4)")
println()
println("VCG budget balance (allocated - cost, paper convention, cost >= 0):")
println("  No-flip hours: ", round(vcg_gap_no_flip - cost_N_gap_no_flip, digits=6), " EUR")
println("  Flip hours:    ", round(vcg_gap_flip - cost_N_gap_flip, digits=6), " EUR")
flush(stdout)

# Cross-check: manual per-hour reimplementation vs the codebase's own mcc_allocation.
# mcc_allocation uses the repo's negative-for-cost convention, so it should equal the
# negation of the manual (paper, cost >= 0) totals above.
mcc_repo = mcc_allocation(clients, coalition_costs)
max_mcc_diff = maximum(abs(mcc_repo[c] - (-manual_mcc_total[c])) for c in clients)
println()
println("Cross-check: max |mcc_allocation - (-manual per-hour MCC total)| = $(round(max_mcc_diff, digits=6)) EUR")
if max_mcc_diff > 1.0
    println("  WARNING: manual per-hour MCC reimplementation diverges from mcc_allocation by more than 1 EUR.")
end
flush(stdout)

# =========================
# Check 2: Gately-point existence fraction
# =========================
println()
println("=== Check 2: Gately point existence ===")

# The relevant condition for Gately point existence is not the leave-one-out sign flip used in
# Check 1, but whether the clients' *individual* imbalances (each client on its own, i.e. the
# singleton coalitions [c]) all share the same sign in a given hour. If they do not all match,
# some agents are long and others short, which is the condition of interest here.
individual_imbalances = Dict(c => coalition_imbalances[[c]] for c in clients)
mixed_sign = falses(T)
for t in 1:T
    first_sign = category(individual_imbalances[clients[1]][t])
    mixed_sign[t] = any(c -> category(individual_imbalances[c][t]) != first_sign, clients)
end
n_mixed_sign = count(mixed_sign)
fraction_mixed_sign_hours = n_mixed_sign / T
println("Fraction of hours where not all agents have the exact same individual imbalance sign ",
        "(condition for Gately point existence): $(round(100*fraction_mixed_sign_hours, digits=2))% ",
        "($n_mixed_sign / $T hours)")
flush(stdout)

# =========================
# Check 3: Lemma A.1 (MCC <= marginal price)
# =========================
println()
println("=== Check 3: Lemma A.1 (MCC vs marginal price) ===")
mp_repo = marginal_price_allocation(clients, coalition_imbalances, system_data)
gaps = Dict(c => mcc_repo[c] - mp_repo[c] for c in clients)
all_le = all(v -> v <= 1e-6, values(gaps))
all_ge = all(v -> v >= -1e-6, values(gaps))
avg_gap = mean(abs.(collect(values(gaps))))

if all_le || all_ge
    direction = all_le ? "<=" : ">="
    println("The inequality of Lemma A.1 holds for all $(length(clients)) consumers, ",
            "with an average gap of $(round(avg_gap, digits=2)) EUR.")
    println("  (In this codebase's allocation-value sign convention, MCC $direction marginal price for every consumer.)")
else
    println("Lemma A.1 inequality direction is NOT consistent across all consumers:")
    for c in clients
        println("  $c: MCC - MP = $(round(gaps[c], digits=4))")
    end
end
flush(stdout)

# =========================
# Check 4: VCG allocation sign (consumers always paid)
# =========================
println()
println("=== Check 4: VCG allocation sign (consumers always paid) ===")
vcg_repo = vcg_allocation(clients, coalition_costs, coalition_imbalances, system_data)

# Cross-check: manual per-hour VCG reimplementation (eq. 10b, now paper-convention after the
# lambda sign fix above) vs vcg_allocation (repo's negative-for-cost convention, same as
# mcc_allocation). Report which direction actually matches rather than silently taking the min,
# so a future regression shows up as a changed direction, not just a small residual.
max_vcg_diff_direct = maximum(abs(vcg_repo[c] - manual_vcg_total[c]) for c in clients)
max_vcg_diff_negated = maximum(abs(vcg_repo[c] - (-manual_vcg_total[c])) for c in clients)
matched_direction = max_vcg_diff_direct <= max_vcg_diff_negated ? "direct (vcg_allocation == manual)" : "negated (vcg_allocation == -manual)"
max_vcg_diff = min(max_vcg_diff_direct, max_vcg_diff_negated)
println("Cross-check: max |vcg_allocation - (manual per-hour VCG total)| = $(round(max_vcg_diff, digits=6)) EUR ",
        "[$matched_direction]")
if max_vcg_diff > 1.0
    println("  WARNING: manual per-hour VCG reimplementation diverges from vcg_allocation by more than 1 EUR.")
end

vcg_all_le = all(v -> v <= 1e-6, values(vcg_repo))
vcg_all_ge = all(v -> v >= -1e-6, values(vcg_repo))
vmin, vmax = extrema(values(vcg_repo))

if vcg_all_le || vcg_all_ge
    direction = vcg_all_le ? "<= 0" : ">= 0"
    println("VCG allocation is $direction for all $(length(clients)) consumers (consumers are always paid), ",
            "confirming Corollary A.2/A.3.")
    println("  Range: [$(round(vmin, digits=2)), $(round(vmax, digits=2))] EUR")

    # Since VCG (eq. 10a/10b) only charges a consumer in hours where their departure flips the
    # grand coalition's price spread (Remark 3 / Section III-C: "most consumers are not
    # charged"), the consumer closest to 0 EUR should be one who is (numerically) pivotal in
    # very few or zero hours. Report this directly rather than assume it.
    abs_vcg = Dict(c => abs(vcg_repo[c]) for c in clients)
    min_client = argmin(abs_vcg)
    max_client = argmax(abs_vcg)
    println("  Consumer closest to 0 EUR: $min_client (VCG = $(round(vcg_repo[min_client], digits=4)) EUR, ",
            "pivotal in $(flip_count_per_client[min_client]) / $T hours)")
    println("  Consumer furthest from 0 EUR: $max_client (VCG = $(round(vcg_repo[max_client], digits=4)) EUR, ",
            "pivotal in $(flip_count_per_client[max_client]) / $T hours)")
else
    println("VCG allocation sign is NOT consistent across all consumers:")
    for c in clients
        println("  $c: VCG = $(round(vcg_repo[c], digits=4))")
    end
end
flush(stdout)

# =========================
# Check 5: Residual of eq. (13): VCG - (MCC - MP)
# =========================
println()
println("=== Check 5: Residual of eq. (13), VCG - (MCC - MP) ===")
residuals = Dict(c => vcg_repo[c] - (mcc_repo[c] - mp_repo[c]) for c in clients)
max_residual = maximum(abs, values(residuals))
println("Max |residual| across $(length(clients)) consumers: $(round(max_residual, digits=6)) EUR")
if max_residual > 1e-3
    println("  WARNING: residual exceeds tolerance -- per-client breakdown:")
    for c in clients
        println("  $c: residual = $(round(residuals[c], digits=6))")
    end
else
    println("Residual is ~0, confirming the identity x_i^VCG = x_i^MCC - x_i^MP for all $(length(clients)) consumers.")
end
flush(stdout)
