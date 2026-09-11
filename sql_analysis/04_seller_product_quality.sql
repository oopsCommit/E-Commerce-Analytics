-- ============================================================================
-- 04_seller_product_quality.sql   (MySQL 8.0+)
-- Phase 2: Seller performance and product/category quality analysis.
-- ============================================================================

USE olist_clean;

-- ---------------------------------------------------------------------------
-- 4.1 Sellers ranked by revenue, volume, and average review score
-- (min 10 orders so a seller with 1 lucky 5-star review doesn't top the list)
-- ---------------------------------------------------------------------------
SELECT
    s.seller_id,
    s.seller_state,
    COUNT(DISTINCT f.order_id)    AS n_orders,
    SUM(f.item_price)             AS revenue,
    ROUND(AVG(r.review_score), 2) AS avg_review_score
FROM fact_order_items f
JOIN dim_sellers s ON s.seller_id = f.seller_id
LEFT JOIN dim_reviews r ON r.order_id = f.order_id
WHERE f.order_status = 'delivered'
GROUP BY s.seller_id, s.seller_state
HAVING n_orders >= 10
ORDER BY revenue DESC;

-- ---------------------------------------------------------------------------
-- 4.2 Flag: high-volume sellers with below-average review scores
-- (the sellers most worth a quality-control conversation)
-- ---------------------------------------------------------------------------
WITH seller_agg AS (
    SELECT
        s.seller_id,
        s.seller_state,
        COUNT(DISTINCT f.order_id)    AS n_orders,
        ROUND(AVG(r.review_score), 2) AS avg_review_score
    FROM fact_order_items f
    JOIN dim_sellers s ON s.seller_id = f.seller_id
    LEFT JOIN dim_reviews r ON r.order_id = f.order_id
    WHERE f.order_status = 'delivered'
    GROUP BY s.seller_id, s.seller_state
    HAVING n_orders >= 20
)
SELECT *
FROM seller_agg
WHERE avg_review_score < 3.5
ORDER BY n_orders DESC;

-- ---------------------------------------------------------------------------
-- 4.3 Categories most associated with 1-2 star vs. 4-5 star reviews
-- (min 30 items so small categories don't produce noisy 100%/0% rows)
-- ---------------------------------------------------------------------------
SELECT
    p.category_name_en,
    COUNT(*)                                                             AS n_items,
    ROUND(AVG(r.review_score), 2)                                        AS avg_review_score,
    ROUND(SUM(CASE WHEN r.review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) * 100, 1) AS pct_1_2_star,
    ROUND(SUM(CASE WHEN r.review_score >= 4 THEN 1 ELSE 0 END) / COUNT(*) * 100, 1) AS pct_4_5_star
FROM fact_order_items f
JOIN dim_products p ON p.product_id = f.product_id
JOIN dim_reviews r ON r.order_id = f.order_id
WHERE f.order_status = 'delivered'
GROUP BY p.category_name_en
HAVING n_items >= 30
ORDER BY pct_1_2_star DESC;

-- ---------------------------------------------------------------------------
-- 4.4 Freight value as % of price, by category
-- ---------------------------------------------------------------------------
SELECT
    p.category_name_en,
    ROUND(AVG(f.item_freight_value), 2)                          AS avg_freight_value,
    ROUND(AVG(f.item_freight_value / f.item_price) * 100, 1)     AS avg_freight_pct_of_price
FROM fact_order_items f
JOIN dim_products p ON p.product_id = f.product_id
WHERE f.order_status = 'delivered' AND f.item_price > 0
GROUP BY p.category_name_en
ORDER BY avg_freight_pct_of_price DESC;

-- ---------------------------------------------------------------------------
-- 4.5 Freight value by seller-state / customer-state pair
-- (state-pair is a rough proxy for shipping distance — dim_geolocation's
-- lat/lng would give a true distance metric; see Section 12 stretch goal)
-- ---------------------------------------------------------------------------
SELECT
    s.seller_state,
    c.customer_state,
    COUNT(*)                                                     AS n_items,
    ROUND(AVG(f.item_freight_value), 2)                          AS avg_freight_value,
    ROUND(AVG(f.item_freight_value / f.item_price) * 100, 1)     AS avg_freight_pct
FROM fact_order_items f
JOIN dim_sellers s ON s.seller_id = f.seller_id
JOIN dim_customers c ON c.customer_id = f.customer_id
WHERE f.order_status = 'delivered' AND f.item_price > 0
GROUP BY s.seller_state, c.customer_state
HAVING n_items >= 20
ORDER BY avg_freight_pct DESC
LIMIT 30;
