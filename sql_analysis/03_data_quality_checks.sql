-- ============================================================================
-- 03_data_quality_checks.sql   (MySQL 8.0+)
-- Phase 1, Step 3: Run BEFORE building the clean model. Nothing here mutates
-- data — it's a diagnostic pass. Every query below should return 0 rows (or
-- a documented, expected non-zero count) before you trust the star schema.
-- Keep this file's output pasted into the repo docs as a "known data
-- quality" log — real projects always have some, and calling it out
-- explicitly is itself a portfolio signal.
-- ============================================================================

USE olist_raw;

-- 1. Duplicate order_ids in orders (should be unique — grain check)
SELECT order_id, COUNT(*) AS n
FROM orders
GROUP BY order_id
HAVING COUNT(*) > 1;

-- 2. Orphaned order_items: items referencing an order_id that doesn't exist
--    in orders. These can't be attributed to a valid order and should be
--    excluded (or investigated) before building fact_order_items.
SELECT oi.order_id
FROM order_items oi
LEFT JOIN orders o ON o.order_id = oi.order_id
WHERE o.order_id IS NULL;

-- 3. Orders with no items at all (valid orders, e.g. cancelled before any
--    item was attached — worth knowing the count, not necessarily a bug).
SELECT o.order_status, COUNT(*) AS orders_with_no_items
FROM orders o
LEFT JOIN order_items oi ON oi.order_id = o.order_id
WHERE oi.order_id IS NULL
GROUP BY o.order_status
ORDER BY orders_with_no_items DESC;

-- 4. Null or non-positive price / freight_value in order_items.
--    MySQL 8's REGEXP uses ICU regex — \d works, but character classes are
--    used here for portability across older MySQL 5.7 installs too.
SELECT *
FROM order_items
WHERE price IS NULL OR price NOT REGEXP '^[0-9]+(\\.[0-9]+)?$' OR CAST(price AS DECIMAL(12,2)) <= 0
   OR freight_value IS NULL OR freight_value NOT REGEXP '^[0-9]+(\\.[0-9]+)?$' OR CAST(freight_value AS DECIMAL(12,2)) < 0;

-- 5. review_score outside the valid 1–5 range, or non-numeric.
SELECT review_id, review_score
FROM order_reviews
WHERE review_score NOT REGEXP '^[0-9]+$' OR CAST(review_score AS UNSIGNED) NOT BETWEEN 1 AND 5;

-- 6. Multiple reviews per order_id (raw data allows this — decide a
--    "latest review wins" rule for the clean layer).
SELECT order_id, COUNT(*) AS n_reviews
FROM order_reviews
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY n_reviews DESC;

-- 7. product_category_name values present in products but MISSING from the
--    translation table (known quirk in this dataset — a handful of raw PT
--    category strings have no English match, e.g. typos in the source).
SELECT DISTINCT p.product_category_name
FROM products p
LEFT JOIN category_translation t
    ON t.product_category_name = p.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name_english IS NULL;

-- 8. Timestamp logic errors: delivered before it was even purchased, or
--    approved before purchased, etc. Anything here is a real anomaly.
--    STR_TO_DATE is used instead of a bare CAST for clarity/portability,
--    though CAST(col AS DATETIME) works fine given the source format.
SELECT order_id, order_purchase_timestamp, order_approved_at,
       order_delivered_carrier_date, order_delivered_customer_date
FROM orders
WHERE (order_approved_at IS NOT NULL
       AND STR_TO_DATE(order_approved_at, '%Y-%m-%d %H:%i:%s')
           < STR_TO_DATE(order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'))
   OR (order_delivered_customer_date IS NOT NULL
       AND STR_TO_DATE(order_delivered_customer_date, '%Y-%m-%d %H:%i:%s')
           < STR_TO_DATE(order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'));

-- 9. customer_id values in orders with no matching row in customers
--    (should be 0 — customers.csv is the superset).
SELECT o.customer_id
FROM orders o
LEFT JOIN customers c ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL;

-- 10. seller_id / product_id in order_items with no matching dimension row.
SELECT oi.seller_id AS missing_id, 'seller' AS missing_type
FROM order_items oi
LEFT JOIN sellers s ON s.seller_id = oi.seller_id
WHERE s.seller_id IS NULL
UNION ALL
SELECT oi.product_id, 'product'
FROM order_items oi
LEFT JOIN products p ON p.product_id = oi.product_id
WHERE p.product_id IS NULL;

-- 11. Geolocation: zip prefixes with widely scattered lat samples (data-entry
--     noise) — informational, will be resolved by taking a median/typical
--     value per zip prefix in the clean layer. Uses ROUND instead of Postgres'
--     bucket approach — same idea, MySQL-native.
SELECT geolocation_zip_code_prefix, COUNT(*) AS n_samples,
       COUNT(DISTINCT ROUND(CAST(geolocation_lat AS DECIMAL(10,4)), 1)) AS distinct_lat_buckets
FROM geolocation
GROUP BY geolocation_zip_code_prefix
HAVING COUNT(DISTINCT ROUND(CAST(geolocation_lat AS DECIMAL(10,4)), 1)) > 3
ORDER BY n_samples DESC
LIMIT 20;

-- 12. order_status distribution — confirms which statuses exist and their
--     volume, so you can decide whether to filter to "delivered" only for
--     revenue/delivery analysis (common practice with this dataset).
SELECT order_status, COUNT(*) AS n
FROM orders
GROUP BY order_status
ORDER BY n DESC;
