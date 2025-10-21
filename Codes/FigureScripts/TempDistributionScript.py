import numpy as np
import matplotlib.pyplot as plt
from scipy import stats

# Set random seed for reproducibility
np.random.seed(42)

# Parameters
num_distributions = 3  # Number of individual distributions to sum
std_dev_single = 100.0  # Normalized standard deviation for single distribution
mean = 0.0  # Mean for distributions

# Create x-axis range
x = np.linspace(-400, 400, 1000)

# 1. Single normal distribution with normalized std = 100
single_normal = stats.norm(mean, std_dev_single)
y_single = single_normal.pdf(x)

# 2. Sum of multiple normal distributions
# When summing N independent normal distributions with std = σ,
# the resulting distribution has std = σ * sqrt(N)
# Original sum would have std = std_dev_single * sqrt(num_distributions)
# But we want it normalized to (original) / 3
sum_std_dev_original = std_dev_single * np.sqrt(num_distributions)
sum_std_dev = sum_std_dev_original / 3
sum_normal = stats.norm(mean, sum_std_dev)
y_sum = sum_normal.pdf(x)

# Create the plot
fig, ax = plt.subplots(figsize=(12, 7))

# Plot single normal distribution
ax.plot(x, y_single, 'b-', linewidth=3, label=f'Single Client Imbalances (σ={std_dev_single:.0f}%)', alpha=0.8)

# Plot sum of normal distributions
ax.plot(x, y_sum, 'r-', linewidth=3, label=f'{num_distributions} Aggregated Imbalances (σ={sum_std_dev:.2f}%)', color='violet', alpha=0.8)

# Fill areas under curves for better visualization
ax.fill_between(x, y_single, alpha=0.2, color='blue')
ax.fill_between(x, y_sum, alpha=0.2, color='violet')

# Formatting
ax.set_xlabel('Value', fontsize=20)
ax.set_ylabel('Probability Density', fontsize=20)
#plt.title('Comparison: Single Client Imbalances vs Sum of Client Imbalances', fontsize=18)
ax.legend(fontsize=16, loc='upper right')
ax.grid(True, alpha=0.3)
ax.set_xlim(-300, 300)

# Add vertical lines at mean
ax.axvline(x=mean, color='black', linestyle='--', linewidth=1, alpha=0.5, label='Mean')

# Remove tick values (keep labels only)
ax.set_xticks([])
ax.set_yticks([])

# Remove plot border (spines)
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.spines['bottom'].set_visible(False)
ax.spines['left'].set_visible(False)

plt.tight_layout()
plt.show()

# Print statistics
print("=" * 60)
print("DISTRIBUTION STATISTICS")
print("=" * 60)
print(f"\nSingle Normal Distribution:")
print(f"  Mean: {mean}")
print(f"  Standard Deviation: {std_dev_single:.0f}")
print(f"  Variance: {std_dev_single**2:.0f}")

print(f"\nSum of {num_distributions} Normal Distributions (normalized):")
print(f"  Mean: {mean}")
print(f"  Standard Deviation: {sum_std_dev:.4f}")
print(f"  Variance: {sum_std_dev**2:.4f}")

print(f"\nNote: Original sum would have std = {std_dev_single:.0f} × √{num_distributions} = {sum_std_dev_original:.2f}")
print(f"Normalized sum has std = {sum_std_dev_original:.2f} / 3 = {sum_std_dev:.2f}")
print("=" * 60)
