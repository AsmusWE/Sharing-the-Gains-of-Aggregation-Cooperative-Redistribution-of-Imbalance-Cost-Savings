# This script is independent of all the other scripts in the project.
# It is used to generate the plot comparing the costs of bell curves under two-price and CVaR aggregationg
# This script is entirely AI generated

import numpy as np
import matplotlib.pyplot as plt
from scipy import stats

# Set random seed for reproducibility
np.random.seed(42)

# Generate two normal distributions with different means and std=1
n_samples = 10000
dist1 = np.random.normal(-1, 1, n_samples)
dist2 = np.random.normal(1, 1, n_samples)

# Add the distributions together
combined_dist = dist1 + dist2

# Calculate the standard deviation of the combined distribution
combined_std = np.std(combined_dist)
print(f"Standard deviation of combined distribution: {combined_std:.4f}")
print(f"Theoretical standard deviation (sqrt(1^2 + 1^2)): {np.sqrt(2):.4f}")

# Calculate areas under curves for values < 0
area1_negative = stats.norm.cdf(0, -1, 1)  # P(X < 0) for dist1
area2_negative = stats.norm.cdf(0, 1, 1)  # P(X < 0) for dist2
area_combined_negative = stats.norm.cdf(0, 0, np.sqrt(2))  # P(X < 0) for combined

print(f"Area under curve < 0 for Distribution 1: {area1_negative:.4f}")
print(f"Area under curve < 0 for Distribution 2: {area2_negative:.4f}")
print(f"Area under curve < 0 for Combined Distribution: {area_combined_negative:.4f}")

# Calculate conditional expectations E[X | X < 0] for each distribution
def conditional_expectation_below_zero(mu, sigma):
    """Calculate E[X | X < 0] for a normal distribution with mean mu and std sigma"""
    z = -mu / sigma  # standardized value at x=0
    phi_z = stats.norm.pdf(z)  # standard normal PDF at z
    Phi_z = stats.norm.cdf(z)  # standard normal CDF at z
    
    if Phi_z > 0:  # avoid division by zero
        return mu - sigma * (phi_z / Phi_z)
    else:
        return mu  # fallback if P(X < 0) ≈ 0

# Calculate conditional expectations (average costs when X < 0)
avg_cost1 = conditional_expectation_below_zero(-1, 1)
avg_cost2 = conditional_expectation_below_zero(1, 1)
avg_cost_combined = conditional_expectation_below_zero(0, np.sqrt(2))

print(f"\nAverage cost when X < 0:")
print(f"Distribution 1: {avg_cost1:.4f}")
print(f"Distribution 2: {avg_cost2:.4f}")
print(f"Combined Distribution: {avg_cost_combined:.4f}")

# Calculate unaggregated average cost (sum of individual costs)
unaggregated_avg_cost = avg_cost1 + avg_cost2
print(f"Unaggregated average cost (sum): {unaggregated_avg_cost:.4f}")

# Calculate average cost under entire curve with values > 0 set to cost = 0
def expected_cost_with_zero_above_threshold(mu, sigma, threshold=0):
    """Calculate E[min(X, 0)] - expected value where positive values are treated as zero cost"""
    # This is equivalent to E[X * I(X < 0)] where I is indicator function
    # For normal distribution: E[X * I(X < threshold)] = mu * Φ(z) - sigma * φ(z)
    # where z = (threshold - mu) / sigma
    z = (threshold - mu) / sigma
    phi_z = stats.norm.pdf(z)  # standard normal PDF at z
    Phi_z = stats.norm.cdf(z)  # standard normal CDF at z
    
    return mu * Phi_z - sigma * phi_z

# Calculate expected costs with zero above threshold
expected_cost1 = expected_cost_with_zero_above_threshold(-1, 1, 0)
expected_cost2 = expected_cost_with_zero_above_threshold(1, 1, 0)
expected_cost_combined = expected_cost_with_zero_above_threshold(0, np.sqrt(2), 0)

print(f"\nExpected cost with zero cost above 0:")
print(f"Distribution 1: {expected_cost1:.4f}")
print(f"Distribution 2: {expected_cost2:.4f}")
print(f"Combined Distribution: {expected_cost_combined:.4f}")

# Calculate unaggregated expected cost (sum of individual expected costs)
unaggregated_expected_cost = expected_cost1 + expected_cost2
print(f"Unaggregated expected cost (sum): {unaggregated_expected_cost:.4f}")

# Calculate CVaR (Conditional Value at Risk) at alpha = 0.1
def cvar_normal(mu, sigma, alpha):
    """Calculate CVaR at confidence level alpha for a normal distribution"""
    # For a normal distribution, CVaR_α = μ - σ * φ(Φ^(-1)(α)) / α
    # where φ is the standard normal PDF and Φ^(-1) is the inverse CDF (quantile)
    z_alpha = stats.norm.ppf(alpha)  # quantile at alpha
    phi_z_alpha = stats.norm.pdf(z_alpha)  # PDF at quantile
    
    return mu - sigma * (phi_z_alpha / alpha)

alpha = 0.1  # 10% worst outcomes
cvar1 = cvar_normal(-1, 1, alpha)
cvar2 = cvar_normal(1, 1, alpha)
cvar_combined = cvar_normal(0, np.sqrt(2), alpha)

print(f"\nCVaR at α = {alpha} (expected value of worst {alpha*100:.0f}% outcomes):")
print(f"Distribution 1: {cvar1:.4f}")
print(f"Distribution 2: {cvar2:.4f}")
print(f"Combined Distribution: {cvar_combined:.4f}")

# Calculate unaggregated CVaR (sum of individual CVaRs)
unaggregated_cvar = cvar1 + cvar2
print(f"Unaggregated CVaR (sum): {unaggregated_cvar:.4f}")

# Calculate the quantiles (VaR) at alpha = 0.1 for reference
var1 = stats.norm.ppf(alpha, -1, 1)
var2 = stats.norm.ppf(alpha, 1, 1)
var_combined = stats.norm.ppf(alpha, 0, np.sqrt(2))

print(f"\nVaR at α = {alpha} ({alpha*100:.0f}% quantile):")
print(f"Distribution 1: {var1:.4f}")
print(f"Distribution 2: {var2:.4f}")
print(f"Combined Distribution: {var_combined:.4f}")

# Create x values for plotting the probability density functions
x = np.linspace(-6, 6, 1000)

# Calculate PDFs for the original distributions
pdf1 = stats.norm.pdf(x, -1, 1)
pdf2 = stats.norm.pdf(x, 1, 1)

# Calculate PDF for the combined distribution (mean=-1+1=0, std=sqrt(2))
pdf_combined = stats.norm.pdf(x, 0, np.sqrt(2))

# Find the maximum y-value across all PDFs to set consistent y-axis
max_y = max(np.max(pdf1), np.max(pdf2), np.max(pdf_combined))
y_limit = max_y * 1.1  # Add 10% padding

# Create the plot with three subplots side by side
fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(20, 7))

# Adjust spacing between subplots to prevent label cutoff
plt.subplots_adjust(left=0.08, right=0.95, top=0.85, bottom=0.15, wspace=0.3)

# Plot Distribution 1
ax1.plot(x, pdf1, 'b-', linewidth=3, label='Distribution 1')
# Highlight area under curve for x < 0
x_fill1 = x[x < 0]
pdf1_fill = pdf1[x < 0]
ax1.fill_between(x_fill1, pdf1_fill, alpha=0.4, color='lightblue', 
                 label=f'Area < 0')
# Add vertical line for expected cost with zero above threshold
ax1.axvline(x=expected_cost1, color='navy', linestyle=':', linewidth=2, 
            label=f'Expected income: {expected_cost1:.3f}')
ax1.set_xlabel('Income', fontsize=12)
ax1.set_ylabel('Probability Density', fontsize=12)
ax1.set_title('Distribution 1\n(μ=-1, σ=1)', fontsize=14)
ax1.grid(True, alpha=0.3)
ax1.set_xlim(-6, 6)
ax1.set_ylim(0, y_limit)
ax1.legend(loc='upper left')

# Plot Distribution 2
ax2.plot(x, pdf2, 'r-', linewidth=3, label='Distribution 2')
# Highlight area under curve for x < 0
x_fill2 = x[x < 0]
pdf2_fill = pdf2[x < 0]
ax2.fill_between(x_fill2, pdf2_fill, alpha=0.4, color='lightcoral', 
                 label=f'Area < 0')
# Add vertical line for expected cost with zero above threshold
ax2.axvline(x=expected_cost2, color='maroon', linestyle=':', linewidth=2, 
            label=f'Expected income: {expected_cost2:.3f}')
ax2.set_xlabel('Income', fontsize=12)
ax2.set_ylabel('Probability Density', fontsize=12)
ax2.set_title('Distribution 2\n(μ=1, σ=1)', fontsize=14)
ax2.grid(True, alpha=0.3)
ax2.set_xlim(-6, 6)
ax2.set_ylim(0, y_limit)
ax2.legend(loc='upper left')

# Plot Combined Distribution
ax3.plot(x, pdf_combined, 'g-', linewidth=3, label=f'Combined Distribution')
# Highlight area under curve for x < 0
x_fill3 = x[x < 0]
pdf_combined_fill = pdf_combined[x < 0]
ax3.fill_between(x_fill3, pdf_combined_fill, alpha=0.4, color='lightgreen', 
                 label=f'Area < 0')
# Add vertical lines for expected costs
ax3.axvline(x=expected_cost_combined, color='darkgreen', linestyle=':', linewidth=2, 
            label=f'Aggregated expected income: {expected_cost_combined:.3f}')
ax3.axvline(x=unaggregated_expected_cost, color='darkorange', linestyle='-.', linewidth=2, 
            label=f'Unaggregated expected income: {unaggregated_expected_cost:.3f}')
ax3.set_xlabel('Income', fontsize=12)
ax3.set_ylabel('Probability Density', fontsize=12)
ax3.set_title(f'Combined Distribution\n(μ=0, σ={np.sqrt(2):.3f})', fontsize=14)
ax3.grid(True, alpha=0.3)
ax3.set_xlim(-6, 6)
ax3.set_ylim(0, y_limit)
ax3.legend(loc='upper left')

# Add a main title for the entire figure
fig.suptitle('Two-price effects of aggregation', fontsize=16, y=0.95)

# Add text box with information on the combined plot
#textstr = f'When adding two independent normal distributions:\nμ_combined = μ₁ + μ₂ = 0 + 0 = 0\nσ_combined = √(σ₁² + σ₂²) = √(1² + 1²) = {np.sqrt(2):.3f}\n\nShaded areas represent P(X < 0)\nAvg cost = E[X | X < 0] (conditional expectation)'
#props = dict(boxstyle='round', facecolor='wheat', alpha=0.8)
#ax3.text(0.02, 0.98, textstr, transform=ax3.transAxes, fontsize=10,
#         verticalalignment='top', bbox=props)

# Don't use tight_layout as it conflicts with subplots_adjust
plt.show()

# Create a separate CVaR-focused plot
fig2, (ax1_cvar, ax2_cvar, ax3_cvar) = plt.subplots(1, 3, figsize=(20, 7))

# Adjust spacing between subplots to prevent label cutoff
plt.subplots_adjust(left=0.08, right=0.95, top=0.85, bottom=0.15, wspace=0.3)

# Plot Distribution 1 with CVaR focus
ax1_cvar.plot(x, pdf1, 'b-', linewidth=3, label='Distribution 1')
# Highlight the worst 10% (CVaR region)
x_cvar1 = x[x <= var1]
pdf1_cvar = stats.norm.pdf(x_cvar1, -1, 1)
ax1_cvar.fill_between(x_cvar1, pdf1_cvar, alpha=0.4, color='lightblue', 
                      label=f'Worst 10% (CVaR region)')
# Add vertical lines
ax1_cvar.axvline(x=cvar1, color='navy', linestyle=':', linewidth=2, 
                 label=f'CVaR (α=0.1): {cvar1:.3f}')
ax1_cvar.set_xlabel('Income', fontsize=12)
ax1_cvar.set_ylabel('Probability Density', fontsize=12)
ax1_cvar.set_title('Distribution 1 - CVaR Analysis\n(μ=-1, σ=1)', fontsize=14)
ax1_cvar.grid(True, alpha=0.3)
ax1_cvar.set_xlim(-6, 6)
ax1_cvar.set_ylim(0, y_limit)
ax1_cvar.legend(loc='upper right', fontsize=10)

# Plot Distribution 2 with CVaR focus
ax2_cvar.plot(x, pdf2, 'r-', linewidth=3, label='Distribution 2')
# Highlight the worst 10% (CVaR region)
x_cvar2 = x[x <= var2]
pdf2_cvar = stats.norm.pdf(x_cvar2, 1, 1)
ax2_cvar.fill_between(x_cvar2, pdf2_cvar, alpha=0.4, color='lightcoral', 
                      label=f'Worst 10% (CVaR region)')
# Add vertical lines
ax2_cvar.axvline(x=cvar2, color='maroon', linestyle=':', linewidth=2, 
                 label=f'CVaR (α=0.1): {cvar2:.3f}')
ax2_cvar.set_xlabel('Income', fontsize=12)
ax2_cvar.set_ylabel('Probability Density', fontsize=12)
ax2_cvar.set_title('Distribution 2 - CVaR Analysis\n(μ=1, σ=1)', fontsize=14)
ax2_cvar.grid(True, alpha=0.3)
ax2_cvar.set_xlim(-6, 6)
ax2_cvar.set_ylim(0, y_limit)
ax2_cvar.legend(loc='upper right', fontsize=10)

# Plot Combined Distribution with CVaR focus
ax3_cvar.plot(x, pdf_combined, 'g-', linewidth=3, label=f'Combined Distribution')
# Highlight the worst 10% (CVaR region)
x_cvar_combined = x[x <= var_combined]
pdf_combined_cvar = stats.norm.pdf(x_cvar_combined, 0, np.sqrt(2))
ax3_cvar.fill_between(x_cvar_combined, pdf_combined_cvar, alpha=0.4, color='lightgreen', 
                      label=f'Worst 10% (CVaR region)')
# Add vertical lines for CVaR comparison
ax3_cvar.axvline(x=cvar_combined, color='darkgreen', linestyle=':', linewidth=2, 
                 label=f'Aggregated CVaR: {cvar_combined:.3f}')
#ax3_cvar.axvline(x=unaggregated_cvar, color='darkorange', linestyle='--', linewidth=3, 
#                 label=f'Unaggregated CVaR: {unaggregated_cvar:.3f}')
# Add text annotation showing the benefit of aggregation
benefit = unaggregated_cvar - cvar_combined
#ax3_cvar.annotate(f'CVaR Benefit of Aggregation:\n{benefit:.3f}', 
#                  xy=(0.02, 0.98), xycoords='axes fraction',
#                  bbox=dict(boxstyle='round,pad=0.5', facecolor='yellow', alpha=0.8),
#                  fontsize=11, verticalalignment='top')
ax3_cvar.set_xlabel('Income', fontsize=12)
ax3_cvar.set_ylabel('Probability Density', fontsize=12)
ax3_cvar.set_title(f'Combined Distribution - CVaR Analysis\n(μ=0, σ={np.sqrt(2):.3f})', fontsize=14)
ax3_cvar.grid(True, alpha=0.3)
ax3_cvar.set_xlim(-6, 6)
ax3_cvar.set_ylim(0, y_limit)
ax3_cvar.legend(loc='upper right', fontsize=10)

# Add a main title for the CVaR figure
fig2.suptitle('CVaR Analysis: Risk Reduction through Aggregation (α = 0.1)', fontsize=16, y=0.95)

plt.show()
