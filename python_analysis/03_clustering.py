"""
03_clustering.py
Phase 3: k-means clustering — a genuinely Python/ML task, not a SQL one.

Two independent clustering exercises:
  1. Validate/refine the SQL-based RFM segments (Phase 2 §3.2) using actual
     k-means rather than manual NTILE() quintile cutoffs.
  2. Cluster products by price/freight/weight/review-score to find natural
     product tiers that category labels alone don't capture.

Run: python 03_clustering.py
Writes: olist_clean.py_customer_clusters, olist_clean.py_product_clusters
"""
import pandas as pd
import numpy as np
from sklearn.cluster import KMeans
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import silhouette_score
from db_connection import get_engine

engine = get_engine()


def pick_k(X_scaled: np.ndarray, k_range=range(5, 6)) -> int:
    """
    Picks k via silhouette score rather than hardcoding a number — the
    silhouette score measures how well-separated the clusters are (higher
    is better, range -1 to 1), so this is a defensible, explainable way to
    choose k instead of guessing.
    """
    scores = {}
    for k in k_range:
        labels = KMeans(n_clusters=k, random_state=42, n_init=10).fit_predict(X_scaled)
        scores[k] = silhouette_score(X_scaled, labels)
        print(f"  k={k}: silhouette score = {scores[k]:.3f}")
    best_k = max(scores, key=scores.get)
    print(f"  -> choosing k={best_k} (highest silhouette score)")
    return best_k


# =============================================================================
# 1. Customer clustering on RFM features
# =============================================================================
def cluster_customers():
    print("=" * 70)
    print("CUSTOMER CLUSTERING (RFM-based)")
    print("=" * 70)

    query = """
        SELECT
            c.customer_unique_id,
            DATEDIFF(
                (SELECT DATE_ADD(MAX(order_purchase_ts), INTERVAL 1 DAY) FROM olist_clean.fact_order_items WHERE order_status='delivered'),
                MAX(f.order_purchase_ts)
            ) AS recency_days,
            COUNT(DISTINCT f.order_id) AS frequency,
            SUM(f.item_price) AS monetary
        FROM olist_clean.fact_order_items f
        JOIN olist_clean.dim_customers c ON c.customer_id = f.customer_id
        WHERE f.order_status = 'delivered'
        GROUP BY c.customer_unique_id
    """
    df = pd.read_sql(query, engine)
    print(f"Loaded {len(df)} customers.")

    # Note: monetary and frequency are heavily right-skewed (a handful of
    # customers spend/order far more than the median) — log-transform
    # before scaling so k-means isn't dominated by a few extreme outliers.
    features = df[["recency_days", "frequency", "monetary"]].copy()
    features["frequency_log"] = np.log1p(features["frequency"])
    features["monetary_log"] = np.log1p(features["monetary"])
    X = features[["recency_days", "frequency_log", "monetary_log"]]

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    print("\nSelecting k via silhouette score:")
    best_k = pick_k(X_scaled)

    kmeans = KMeans(n_clusters=best_k, random_state=42, n_init=10)
    df["cluster"] = kmeans.fit_predict(X_scaled)

    # Label clusters by their characteristics (highest monetary = "Best",
    # highest recency_days = "Churned", etc.) rather than leaving them as
    # unlabeled 0/1/2/... — makes the Power BI output interpretable.
    cluster_summary = df.groupby("cluster")[["recency_days", "frequency", "monetary"]].mean()
    print("\nCluster centers (original units):")
    print(cluster_summary.round(2))

    # Rank clusters by a simple composite score to assign human labels
    cluster_summary["rank_score"] = (
        cluster_summary["monetary"].rank() + cluster_summary["frequency"].rank()
        - cluster_summary["recency_days"].rank()
    )
    ordered = cluster_summary.sort_values("rank_score", ascending=False).index.tolist()
    label_names = ["Best Customers", "Promising", "Needs Attention", "At Risk", "Lost"][:len(ordered)]
    label_map = dict(zip(ordered, label_names))
    df["cluster_label"] = df["cluster"].map(label_map)

    print("\nCluster sizes:")
    print(df["cluster_label"].value_counts())

    df.drop(columns=["cluster"]).to_sql(
        "py_customer_clusters", engine, schema="olist_clean", if_exists="replace", index=False
    )
    print(f"\nWrote {len(df)} rows to olist_clean.py_customer_clusters")


# =============================================================================
# 2. Product clustering on price / freight / weight / review score
# =============================================================================
def cluster_products():
    print("\n" + "=" * 70)
    print("PRODUCT CLUSTERING")
    print("=" * 70)

    query = """
        SELECT
            p.product_id,
            p.category_name_en,
            AVG(f.item_price) AS avg_price,
            AVG(f.item_freight_value) AS avg_freight,
            p.product_weight_g,
            AVG(r.review_score) AS avg_review_score,
            COUNT(DISTINCT f.order_id) AS n_orders
        FROM olist_clean.fact_order_items f
        JOIN olist_clean.dim_products p ON p.product_id = f.product_id
        LEFT JOIN olist_clean.dim_reviews r ON r.order_id = f.order_id
        WHERE f.order_status = 'delivered'
        GROUP BY p.product_id, p.category_name_en, p.product_weight_g
        HAVING n_orders >= 3   -- drop one-off products; too little signal to cluster meaningfully
    """
    df = pd.read_sql(query, engine)
    df = df.dropna(subset=["avg_price", "avg_freight", "product_weight_g", "avg_review_score"])
    print(f"Loaded {len(df)} products with enough order history to cluster.")

    features = df[["avg_price", "avg_freight", "product_weight_g", "avg_review_score"]].copy()
    features["avg_price_log"] = np.log1p(features["avg_price"])
    features["avg_freight_log"] = np.log1p(features["avg_freight"])
    features["weight_log"] = np.log1p(features["product_weight_g"])
    X = features[["avg_price_log", "avg_freight_log", "weight_log", "avg_review_score"]]

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    print("\nSelecting k via silhouette score:")
    best_k = pick_k(X_scaled, k_range=range(4,5))

    kmeans = KMeans(n_clusters=best_k, random_state=42, n_init=10)
    df["cluster"] = kmeans.fit_predict(X_scaled)

    cluster_summary = df.groupby("cluster")[["avg_price", "avg_freight", "product_weight_g", "avg_review_score"]].mean()
    print("\nCluster centers (original units):")
    print(cluster_summary.round(2))

    df.to_sql("py_product_clusters", engine, schema="olist_clean", if_exists="replace", index=False)
    print(f"\nWrote {len(df)} rows to olist_clean.py_product_clusters")


if __name__ == "__main__":
    cluster_customers()
    cluster_products()
    print("\nBoth clustering tables are now queryable from MySQL and joinable")
    print("in Power BI: py_customer_clusters on customer_unique_id, "
          "py_product_clusters on product_id.")
