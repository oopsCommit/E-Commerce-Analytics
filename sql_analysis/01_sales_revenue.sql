-- ============================================================================
-- 01_sales_revenue.sql   (MySQL 8.0+)
-- Phase 2: Sales & Revenue analysis, built on olist_clean.
--
-- CONVENTION USED THROUGHOUT PHASE 2: filtered to order_status = 'delivered'
-- unless noted otherwise. Cancelled/unavailable/returned orders were never
-- fulfilled, so counting their price toward "revenue" overstates it — this
-- is standard practice with this dataset and worth stating explicitly in
-- your write-up rather than leaving it as a silent choice.
-- ============================================================================

USE olist_clean;

-- ---------------------------------------------------------------------------
-- 1.1 Monthly revenue & order volume trend, with month-over-month growth %
-- ---------------------------------------------------------------------------
WITH monthly AS (
    SELECT
        d.year_month_key,
        COUNT(DISTINCT f.order_id) AS n_orders,
        SUM(f.item_price)          AS revenue
    FROM fact_order_items f
    JOIN dim_date d ON d.date_key = f.order_purchase_date
    WHERE f.order_status = 'delivered'
    GROUP BY d.year_month_key
)
SELECT
    year_month_key,
    n_orders,
    revenue,
    ROUND(revenue / NULLIF(LAG(revenue) OVER (ORDER BY year_month_key), 0) * 100 - 100, 1)  AS revenue_mom_growth_pct,
    ROUND(n_orders / NULLIF(LAG(n_orders) OVER (ORDER BY year_month_key), 0) * 100 - 100, 1) AS orders_mom_growth_pct
FROM monthly
ORDER BY year_month_key;

-- ---------------------------------------------------------------------------
-- 1.2 Quarterly revenue and order volume
-- ---------------------------------------------------------------------------
SELECT
    d.year, d.quarter,
    SUM(f.item_price)          AS revenue,
    COUNT(DISTINCT f.order_id) AS n_orders
FROM fact_order_items f
JOIN dim_date d ON d.date_key = f.order_purchase_date
WHERE f.order_status = 'delivered'
GROUP BY d.year, d.quarter
ORDER BY d.year, d.quarter;

-- ---------------------------------------------------------------------------
-- 1.3 Revenue and average order value (AOV) by customer state
-- ---------------------------------------------------------------------------
SELECT
    c.customer_state,
    SUM(f.item_price)                                       AS revenue,
    COUNT(DISTINCT f.order_id)                              AS n_orders,
    ROUND(SUM(f.item_price) / COUNT(DISTINCT f.order_id), 2) AS avg_order_value
FROM fact_order_items f
JOIN dim_customers c ON c.customer_id = f.customer_id
WHERE f.order_status = 'delivered'
GROUP BY c.customer_state
ORDER BY revenue DESC;

-- ---------------------------------------------------------------------------
-- 1.4 Revenue and AOV by product category
-- ---------------------------------------------------------------------------
SELECT
    p.category_name_en,
    SUM(f.item_price)                                       AS revenue,
    COUNT(DISTINCT f.order_id)                              AS n_orders,
    ROUND(SUM(f.item_price) / COUNT(DISTINCT f.order_id), 2) AS avg_order_value
FROM fact_order_items f
JOIN dim_products p ON p.product_id = f.product_id
WHERE f.order_status = 'delivered'
GROUP BY p.category_name_en
ORDER BY revenue DESC;

-- ---------------------------------------------------------------------------
-- 1.5a Top 10 categories BY REVENUE
-- ---------------------------------------------------------------------------
SELECT p.category_name_en, SUM(f.item_price) AS revenue, COUNT(DISTINCT f.order_id) AS n_orders
FROM fact_order_items f
JOIN dim_products p ON p.product_id = f.product_id
WHERE f.order_status = 'delivered'
GROUP BY p.category_name_en
ORDER BY revenue DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 1.5b Top 10 categories BY ORDER COUNT — compare against 1.5a: a category
-- can rank high on volume but low on revenue (cheap, frequently bought
-- items) or vice versa (expensive, rarely bought) — that contrast is the
-- actual insight, not either list alone.
-- ---------------------------------------------------------------------------
SELECT p.category_name_en, COUNT(DISTINCT f.order_id) AS n_orders, SUM(f.item_price) AS revenue
FROM fact_order_items f
JOIN dim_products p ON p.product_id = f.product_id
WHERE f.order_status = 'delivered'
GROUP BY p.category_name_en
ORDER BY n_orders DESC
LIMIT 10;
