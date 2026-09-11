-- ============================================================================
-- 02_delivery_performance.sql   (MySQL 8.0+)
-- Phase 2: Delivery performance analysis, built on olist_clean.
--
-- GRAIN WARNING that applies to every query in this file: fact_order_items
-- is one row per ITEM, but delivery timestamps are recorded once per ORDER.
-- A 3-item order would have its delivery time counted 3 times if you
-- AVG() straight off fact_order_items. Every query below dedupes to one
-- row per order FIRST (via a subquery/CTE), then aggregates — this is the
-- single most common correctness bug with this dataset's delivery metrics.
-- ============================================================================

USE olist_clean;

-- ---------------------------------------------------------------------------
-- 2.1 % of orders delivered late, by customer state
-- ---------------------------------------------------------------------------
WITH order_level AS (
    SELECT DISTINCT f.order_id, f.customer_id, f.is_late_delivery
    FROM fact_order_items f
    WHERE f.order_status = 'delivered' AND f.is_late_delivery IS NOT NULL
)
SELECT
    c.customer_state,
    COUNT(*)                                            AS n_orders,
    SUM(o.is_late_delivery)                              AS n_late,
    ROUND(SUM(o.is_late_delivery) / COUNT(*) * 100, 1)   AS pct_late
FROM order_level o
JOIN dim_customers c ON c.customer_id = o.customer_id
GROUP BY c.customer_state
ORDER BY pct_late DESC;

-- ---------------------------------------------------------------------------
-- 2.2 % of orders delivered late, by product category
-- (Grain note: a multi-category order would count once per category here,
-- which is fine — the question is "which categories tend to run late",
-- not "how many orders were late" — that's 2.1.)
-- ---------------------------------------------------------------------------
SELECT
    p.category_name_en,
    COUNT(*)                                          AS n_items,
    SUM(f.is_late_delivery)                            AS n_late,
    ROUND(SUM(f.is_late_delivery) / COUNT(*) * 100, 1) AS pct_late
FROM fact_order_items f
JOIN dim_products p ON p.product_id = f.product_id
WHERE f.order_status = 'delivered' AND f.is_late_delivery IS NOT NULL
GROUP BY p.category_name_en
HAVING COUNT(*) >= 30   -- drop tiny categories where one late order swings % wildly
ORDER BY pct_late DESC;

-- ---------------------------------------------------------------------------
-- 2.3 Average delivery time broken into stages (order-level, deduped)
-- ---------------------------------------------------------------------------
WITH order_level AS (
    SELECT DISTINCT
        order_id, order_purchase_ts, order_approved_ts,
        delivered_carrier_ts, delivered_customer_ts, purchase_to_delivery_seconds
    FROM fact_order_items
    WHERE order_status = 'delivered'
)
SELECT
    ROUND(AVG(TIMESTAMPDIFF(HOUR, order_purchase_ts, order_approved_ts)) / 24, 2)      AS avg_days_purchase_to_approval,
    ROUND(AVG(TIMESTAMPDIFF(HOUR, order_approved_ts, delivered_carrier_ts)) / 24, 2)   AS avg_days_approval_to_carrier,
    ROUND(AVG(TIMESTAMPDIFF(HOUR, delivered_carrier_ts, delivered_customer_ts)) / 24, 2) AS avg_days_carrier_to_customer,
    ROUND(AVG(purchase_to_delivery_seconds) / 86400, 2)                                AS avg_days_total
FROM order_level;

-- ---------------------------------------------------------------------------
-- 2.4 Delivery status vs. average review score
-- ---------------------------------------------------------------------------
WITH order_level AS (
    SELECT DISTINCT order_id, is_late_delivery
    FROM fact_order_items
    WHERE order_status = 'delivered' AND is_late_delivery IS NOT NULL
)
SELECT
    CASE WHEN o.is_late_delivery = 1 THEN 'Late' ELSE 'On-time' END AS delivery_status,
    COUNT(DISTINCT o.order_id)     AS n_orders,
    ROUND(AVG(r.review_score), 2)  AS avg_review_score
FROM order_level o
JOIN dim_reviews r ON r.order_id = o.order_id
GROUP BY delivery_status;

-- Note: this is a descriptive aggregation, not a significance test — it
-- tells you the average score differs, not whether that difference is
-- statistically meaningful given sample size and variance. That's exactly
-- the kind of question that belongs in Phase 3 (Python), not here — see
-- phase3_python/01_statistical_tests.py, which runs a proper t-test on
-- this same on-time vs. late split.

-- ---------------------------------------------------------------------------
-- 2.5 Estimated vs. actual delivery gap distribution (order-level)
-- How many days early/late, bucketed — useful for a Power BI histogram.
-- ---------------------------------------------------------------------------
WITH order_level AS (
    SELECT DISTINCT order_id, delivered_customer_ts, estimated_delivery_ts
    FROM fact_order_items
    WHERE order_status = 'delivered' AND delivered_customer_ts IS NOT NULL
)
SELECT
    TIMESTAMPDIFF(DAY, estimated_delivery_ts, delivered_customer_ts) AS days_vs_estimate,  -- negative = early
    COUNT(*) AS n_orders
FROM order_level
GROUP BY days_vs_estimate
ORDER BY days_vs_estimate;
