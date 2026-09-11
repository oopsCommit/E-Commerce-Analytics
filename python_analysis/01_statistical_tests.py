"""
01_statistical_tests.py
Phase 3: statistical tests SQL genuinely can't do — significance testing,
not just descriptive aggregation. Each test below follows up directly on a
descriptive finding from Phase 2's SQL.

Every test reports THREE things, not just a p-value:
  1. Statistical significance (p-value) — is this gap likely to be real,
     or could it show up by chance?
  2. Effect size (Cohen's d / Cramer's V) — how BIG is the gap, in a
     standardized unit that's comparable across different tests/variables?
  3. A plain-language interpretation of the effect size, using
     conventional benchmarks.
A statistically significant result with a negligible effect size (common
with ~100k rows) is not the same finding as a significant result with a
large effect size — reporting only the p-value conflates the two.

Run: python 01_statistical_tests.py
Writes results to a new table: olist_clean.py_statistical_test_results
(so Power BI / the README can reference test results without re-running
Python — one unified model, not a disconnected notebook).
"""
import numpy as np
import pandas as pd
from scipy import stats
from sqlalchemy import text
from db_connection import get_engine

engine = get_engine()


def cohens_d(group1: pd.Series, group2: pd.Series) -> float:
    """
    Standardized mean difference for two independent groups. Uses the
    pooled standard deviation, so the result is in units of "how many
    standard deviations apart are these two group means" — comparable
    across any two numeric variables, unlike the raw difference.
    """
    n1, n2 = len(group1), len(group2)
    var1, var2 = group1.var(ddof=1), group2.var(ddof=1)
    pooled_std = np.sqrt(((n1 - 1) * var1 + (n2 - 1) * var2) / (n1 + n2 - 2))
    return (group1.mean() - group2.mean()) / pooled_std


def interpret_cohens_d(d: float) -> str:
    ad = abs(d)
    if ad < 0.2:
        return "negligible"
    elif ad < 0.5:
        return "small"
    elif ad < 0.8:
        return "medium"
    else:
        return "large"


def cramers_v(chi2: float, n: int, contingency_shape: tuple) -> float:
    """
    Standardized association strength for two categorical variables,
    derived from the chi-square statistic. Bounded 0-1 regardless of
    sample size or table shape, unlike chi2 itself (which grows with n
    even when the underlying association doesn't change) — this is what
    makes it comparable across tests with different sample sizes.
    """
    r, c = contingency_shape
    return np.sqrt(chi2 / (n * (min(r, c) - 1)))


def interpret_cramers_v(v: float) -> str:
    if v < 0.1:
        return "negligible"
    elif v < 0.3:
        return "weak"
    elif v < 0.5:
        return "moderate"
    else:
        return "strong"


def save_results(rows: list[dict]):
    """Append test results to a small results table Power BI/README can read."""
    df = pd.DataFrame(rows)
    df.to_sql("py_statistical_test_results", engine, schema="olist_clean",
              if_exists="replace", index=False)
    print(f"\nWrote {len(df)} rows to olist_clean.py_statistical_test_results")


results = []

# =============================================================================
# TEST 1: Is the review-score difference between on-time and late deliveries
# statistically significant, or could it be sampling noise?
# Follows up on Phase 2 §2.4 (02_delivery_performance.sql), which showed a
# descriptive average-score gap but no significance test.
# =============================================================================
print("=" * 70)
print("TEST 1: On-time vs. late delivery — review score (independent t-test)")
print("=" * 70)

query_delivery = """
    SELECT
        CASE WHEN o.is_late_delivery = 1 THEN 'late' ELSE 'on_time' END AS delivery_status,
        r.review_score
    FROM (
        SELECT DISTINCT order_id, is_late_delivery
        FROM olist_clean.fact_order_items
        WHERE order_status = 'delivered' AND is_late_delivery IS NOT NULL
    ) o
    JOIN olist_clean.dim_reviews r ON r.order_id = o.order_id
"""
df_delivery = pd.read_sql(query_delivery, engine)

on_time_scores = df_delivery.loc[df_delivery.delivery_status == "on_time", "review_score"]
late_scores = df_delivery.loc[df_delivery.delivery_status == "late", "review_score"]

t_stat, p_value = stats.ttest_ind(on_time_scores, late_scores, equal_var=False)  # Welch's t-test — doesn't assume equal variance
d = cohens_d(on_time_scores, late_scores)
d_interpretation = interpret_cohens_d(d)

print(f"On-time mean score: {on_time_scores.mean():.3f} (n={len(on_time_scores)})")
print(f"Late mean score:    {late_scores.mean():.3f} (n={len(late_scores)})")
print(f"t-statistic: {t_stat:.3f}, p-value: {p_value:.2e}")
print(f"Cohen's d: {d:.3f}  ({d_interpretation} effect)")
print("=> Statistically significant (p < 0.05)" if p_value < 0.05 else "=> Not statistically significant")
print(f"=> Practically {d_interpretation}: a {d_interpretation}-sized effect by conventional benchmarks "
      f"(0.2=small, 0.5=medium, 0.8=large), independent of the p-value.")

results.append({
    "test_name": "on_time_vs_late_review_score_ttest",
    "test_type": "Welch's t-test",
    "statistic": round(float(t_stat), 4),
    "p_value": float(p_value),
    "significant_at_0.05": bool(p_value < 0.05),
    "effect_size_type": "Cohen's d",
    "effect_size": round(float(d), 4),
    "effect_size_interpretation": d_interpretation,
    "notes": f"on_time mean={on_time_scores.mean():.3f} (n={len(on_time_scores)}), "
             f"late mean={late_scores.mean():.3f} (n={len(late_scores)})",
})

# =============================================================================
# TEST 2: Is payment type associated with review score category?
# (chi-square test of independence — both variables are categorical)
# =============================================================================
print("\n" + "=" * 70)
print("TEST 2: Payment type vs. review-score category (chi-square)")
print("=" * 70)

query_payment = """
    SELECT
        op.primary_payment_type,
        r.review_score
    FROM (
        SELECT order_id,
               SUBSTRING_INDEX(GROUP_CONCAT(payment_type ORDER BY payment_value DESC), ',', 1) AS primary_payment_type
        FROM olist_clean.fact_order_payments
        GROUP BY order_id
    ) op
    JOIN olist_clean.dim_reviews r ON r.order_id = op.order_id
"""
df_payment = pd.read_sql(query_payment, engine)
df_payment["score_bucket"] = pd.cut(
    df_payment["review_score"], bins=[0, 2, 3, 5],
    labels=["low_1_2", "mid_3", "high_4_5"]
)

contingency = pd.crosstab(df_payment["primary_payment_type"], df_payment["score_bucket"])
chi2, p_value2, dof, expected = stats.chi2_contingency(contingency)
n_total = contingency.values.sum()
v = cramers_v(chi2, n_total, contingency.shape)
v_interpretation = interpret_cramers_v(v)

print(contingency)
print(f"\nchi2 = {chi2:.3f}, dof = {dof}, p-value = {p_value2:.2e}")
print(f"Cramer's V: {v:.3f}  ({v_interpretation} association)")
print("=> Statistically significant association (p < 0.05)" if p_value2 < 0.05 else "=> No significant association")
print(f"=> Practically {v_interpretation}: a {v_interpretation} association by conventional benchmarks "
      f"(<0.1=negligible, 0.1-0.3=weak, 0.3-0.5=moderate, >0.5=strong).")

results.append({
    "test_name": "payment_type_vs_review_score_chi_square",
    "test_type": "Chi-square test of independence",
    "statistic": round(float(chi2), 4),
    "p_value": float(p_value2),
    "significant_at_0.05": bool(p_value2 < 0.05),
    "effect_size_type": "Cramer's V",
    "effect_size": round(float(v), 4),
    "effect_size_interpretation": v_interpretation,
    "notes": f"dof={dof}, contingency table shape={contingency.shape}",
})

# =============================================================================
# TEST 3: Is customer state associated with late-delivery rate?
# =============================================================================
print("\n" + "=" * 70)
print("TEST 3: Customer state vs. late-delivery rate (chi-square)")
print("=" * 70)

query_state = """
    SELECT c.customer_state, o.is_late_delivery
    FROM (
        SELECT DISTINCT order_id, customer_id, is_late_delivery
        FROM olist_clean.fact_order_items
        WHERE order_status = 'delivered' AND is_late_delivery IS NOT NULL
    ) o
    JOIN olist_clean.dim_customers c ON c.customer_id = o.customer_id
"""
df_state = pd.read_sql(query_state, engine)
contingency_state = pd.crosstab(df_state["customer_state"], df_state["is_late_delivery"])
chi2_state, p_value3, dof_state, _ = stats.chi2_contingency(contingency_state)
n_total_state = contingency_state.values.sum()
v_state = cramers_v(chi2_state, n_total_state, contingency_state.shape)
v_state_interpretation = interpret_cramers_v(v_state)

print(f"chi2 = {chi2_state:.3f}, dof = {dof_state}, p-value = {p_value3:.2e}")
print(f"Cramer's V: {v_state:.3f}  ({v_state_interpretation} association)")
print("=> Statistically significant association (p < 0.05)" if p_value3 < 0.05 else "=> No significant association")
print(f"=> Practically {v_state_interpretation}: a {v_state_interpretation} association by conventional benchmarks.")

results.append({
    "test_name": "customer_state_vs_late_delivery_chi_square",
    "test_type": "Chi-square test of independence",
    "statistic": round(float(chi2_state), 4),
    "p_value": float(p_value3),
    "significant_at_0.05": bool(p_value3 < 0.05),
    "effect_size_type": "Cramer's V",
    "effect_size": round(float(v_state), 4),
    "effect_size_interpretation": v_state_interpretation,
    "notes": f"dof={dof_state}, {contingency_state.shape[0]} states compared",
})

# =============================================================================
# Save everything
# =============================================================================
save_results(results)

print("\nDone. Every test above reports significance (p-value) AND effect size")
print("(Cohen's d or Cramer's V) separately — with ~100k rows, statistical")
print("significance alone is nearly guaranteed even for tiny, business-irrelevant")
print("gaps. The effect size is what actually tells you whether a result is")
print("worth acting on.")
