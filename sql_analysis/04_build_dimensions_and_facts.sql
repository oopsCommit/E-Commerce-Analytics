-- ============================================================================
-- 04_build_dimensions_and_facts.sql   (MySQL 8.0+)
-- Phase 1, Step 4: Build the clean star-schema-ish model from olist_raw.*
-- Run 03_data_quality_checks.sql first and resolve/accept its findings —
-- the exclusions below (e.g. orphaned items, bad prices) are a direct
-- response to what that file finds.
--
-- REQUIRES MySQL 8.0+ (recursive CTEs and window functions — both missing
-- in MySQL 5.7). If you're stuck on 5.7, the date table needs a numbers-
-- table workaround and the window-function steps need correlated
-- subqueries instead; ask and I'll write that variant.
-- ============================================================================
SET SESSION cte_max_recursion_depth = 5000;



CREATE DATABASE IF NOT EXISTS olist_clean
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- dim_date: a proper calendar table for time intelligence (fiscal-friendly,
-- reusable in both SQL window functions and the Power BI model later).
-- MySQL has no generate_series, so we build the date range with a
-- recursive CTE instead, then materialize it into a real table.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.dim_date;

CREATE TABLE olist_clean.dim_date (
    date_key      DATE PRIMARY KEY,
    year          INT,
    quarter       INT,
    month         INT,
    month_name    VARCHAR(3),
    year_month_key    VARCHAR(7),
    iso_week      INT,
    day_of_week   INT,      -- 1=Sunday ... 7=Saturday (MySQL DAYOFWEEK convention)
    day_name      VARCHAR(3),
    is_weekend    TINYINT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO olist_clean.dim_date
WITH RECURSIVE date_range AS (
    SELECT DATE('2016-01-01') AS d
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM date_range WHERE d < '2019-12-31'
)
SELECT
    d,
    YEAR(d),
    QUARTER(d),
    MONTH(d),
    DATE_FORMAT(d, '%b'),
    DATE_FORMAT(d, '%Y-%m'),
    WEEK(d, 3)                        AS iso_week,   -- mode 3 = ISO week
    DAYOFWEEK(d)                      AS day_of_week,
    DATE_FORMAT(d, '%a'),
    DAYOFWEEK(d) IN (1, 7)            AS is_weekend  -- 1=Sun, 7=Sat
FROM date_range;
-- If you hit "Recursion depth exceeded" (default cte_max_recursion_depth is
-- 1000, and this date range is ~1460 days), run this first, in the same
-- session, before the INSERT above:
--   SET SESSION cte_max_recursion_depth = 2000;

-- ---------------------------------------------------------------------------
-- dim_customers: 1 row per customer_id (matches the fact table FK), with
-- customer_unique_id exposed for repeat-purchase logic downstream.
-- MySQL has no INITCAP — city names are kept as shipped rather than
-- title-cased; that's a cosmetic nicety, not a correctness issue, and can
-- be done in Power BI/DAX or Python if you want it for display.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.dim_customers;
CREATE TABLE olist_clean.dim_customers AS
SELECT DISTINCT
    c.customer_id,
    c.customer_unique_id,
    CAST(NULLIF(c.customer_zip_code_prefix, '') AS UNSIGNED) AS customer_zip_prefix,
    c.customer_city                                    AS customer_city,
    UPPER(c.customer_state)                             AS customer_state
FROM olist_raw.customers c;

ALTER TABLE olist_clean.dim_customers
    MODIFY customer_id VARCHAR(64) NOT NULL,
    ADD PRIMARY KEY (customer_id),
    ADD INDEX idx_dim_customers_unique_id (customer_unique_id);

-- ---------------------------------------------------------------------------
-- dim_sellers
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.dim_sellers;
CREATE TABLE olist_clean.dim_sellers AS
SELECT DISTINCT
    s.seller_id,
    CAST(NULLIF(s.seller_zip_code_prefix, '') AS UNSIGNED) AS seller_zip_prefix,
    s.seller_city                             AS seller_city,
    UPPER(s.seller_state)                     AS seller_state
FROM olist_raw.sellers s;

ALTER TABLE olist_clean.dim_sellers
    MODIFY seller_id VARCHAR(64) NOT NULL,
    ADD PRIMARY KEY (seller_id);

-- ---------------------------------------------------------------------------
-- dim_products: joins in the EN category name; falls back to the raw PT
-- name (flagged) when no translation exists, rather than dropping the
-- product — see data-quality finding #7.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.dim_products;
CREATE TABLE olist_clean.dim_products AS
SELECT
    p.product_id,
    COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category_name_en,
    p.product_category_name                                                        AS category_name_pt_raw,
    (t.product_category_name_english IS NULL)                                       AS category_translation_missing,
    CAST(NULLIF(p.product_weight_g, '') AS DECIMAL(10,2))   AS product_weight_g,
    CAST(NULLIF(p.product_length_cm, '') AS DECIMAL(10,2))  AS product_length_cm,
    CAST(NULLIF(p.product_height_cm, '') AS DECIMAL(10,2))  AS product_height_cm,
    CAST(NULLIF(p.product_width_cm, '') AS DECIMAL(10,2))   AS product_width_cm,
    CAST(NULLIF(p.product_photos_qty, '') AS UNSIGNED)      AS product_photos_qty
FROM olist_raw.products p
LEFT JOIN olist_raw.category_translation t
    ON t.product_category_name = p.product_category_name;

ALTER TABLE olist_clean.dim_products
    MODIFY product_id VARCHAR(64) NOT NULL,
    ADD PRIMARY KEY (product_id);

-- ---------------------------------------------------------------------------
-- dim_reviews: dedupe to ONE review per order — latest by
-- review_answer_timestamp — per data-quality finding #6.
-- MySQL has no DISTINCT ON, so this uses ROW_NUMBER() OVER (...) = 1 instead
-- — the standard MySQL 8 pattern for "latest row per group".
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.dim_reviews;

CREATE TABLE olist_clean.dim_reviews AS
SELECT 
    review_id,
    order_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_ts,
    review_answer_ts
FROM (
    SELECT
        review_id,
        order_id,
        CAST(review_score AS UNSIGNED) AS review_score,
        NULLIF(review_comment_title, '') AS review_comment_title,
        NULLIF(review_comment_message, '') AS review_comment_message,

        CASE 
            WHEN review_creation_date REGEXP 
                '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
            THEN STR_TO_DATE(review_creation_date, '%Y-%m-%d %H:%i:%s')
            ELSE NULL
        END AS review_creation_ts,

        CASE 
            WHEN review_answer_timestamp REGEXP 
                '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
            THEN STR_TO_DATE(review_answer_timestamp, '%Y-%m-%d %H:%i:%s')
            ELSE NULL
        END AS review_answer_ts,

        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY
                CASE 
                    WHEN review_answer_timestamp REGEXP 
                        '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
                    THEN STR_TO_DATE(
                        review_answer_timestamp, 
                        '%Y-%m-%d %H:%i:%s'
                    )
                    ELSE NULL
                END DESC
        ) AS rn

    FROM olist_raw.order_reviews

    WHERE review_score REGEXP '^[0-9]+$'
      AND CAST(review_score AS UNSIGNED) BETWEEN 1 AND 5
) ranked
WHERE rn = 1;

ALTER TABLE olist_clean.dim_reviews
    MODIFY order_id VARCHAR(64) NOT NULL,
    ADD PRIMARY KEY (order_id);

-- ---------------------------------------------------------------------------
-- fact_order_items: the core fact table. Grain = 1 row per order item.
-- Excludes items that are orphaned (no matching order — finding #2) or have
-- invalid price/freight (finding #4).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.fact_order_items;

CREATE TABLE olist_clean.fact_order_items AS
SELECT
    oi.order_id,
    CAST(oi.order_item_id AS UNSIGNED) AS order_item_seq,
    oi.product_id,
    oi.seller_id,
    o.customer_id,
    o.order_status,

    CAST(oi.price AS DECIMAL(12,2)) AS item_price,
    CAST(oi.freight_value AS DECIMAL(12,2)) AS item_freight_value,

    /* Shipping limit */
    CASE
        WHEN oi.shipping_limit_date REGEXP
            '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN STR_TO_DATE(oi.shipping_limit_date, '%Y-%m-%d %H:%i:%s')
        ELSE NULL
    END AS shipping_limit_ts,

    /* Purchase timestamp */
    CASE
        WHEN o.order_purchase_timestamp REGEXP
            '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s')
        ELSE NULL
    END AS order_purchase_ts,

    /* Approved timestamp */
    CASE
        WHEN o.order_approved_at REGEXP
            '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN STR_TO_DATE(o.order_approved_at, '%Y-%m-%d %H:%i:%s')
        ELSE NULL
    END AS order_approved_ts,

    /* Delivered to carrier */
    CASE
        WHEN o.order_delivered_carrier_date REGEXP
            '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN STR_TO_DATE(o.order_delivered_carrier_date, '%Y-%m-%d %H:%i:%s')
        ELSE NULL
    END AS delivered_carrier_ts,

    /* Delivered to customer */
    CASE
        WHEN o.order_delivered_customer_date REGEXP
            '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN STR_TO_DATE(o.order_delivered_customer_date, '%Y-%m-%d %H:%i:%s')
        ELSE NULL
    END AS delivered_customer_ts,

    /* Estimated delivery */
    CASE
        WHEN o.order_estimated_delivery_date REGEXP
            '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN STR_TO_DATE(o.order_estimated_delivery_date, '%Y-%m-%d %H:%i:%s')
        ELSE NULL
    END AS estimated_delivery_ts,

    /* Date for joining to dim_date */
    CASE
        WHEN o.order_purchase_timestamp REGEXP
            '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN DATE(STR_TO_DATE(
            o.order_purchase_timestamp,
            '%Y-%m-%d %H:%i:%s'
        ))
        ELSE NULL
    END AS order_purchase_date,

    /* Purchase → delivery duration */
    CASE
        WHEN o.order_purchase_timestamp REGEXP
                 '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
         AND o.order_delivered_customer_date REGEXP
                 '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN TIMESTAMPDIFF(
            SECOND,
            STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'),
            STR_TO_DATE(o.order_delivered_customer_date, '%Y-%m-%d %H:%i:%s')
        )
        ELSE NULL
    END AS purchase_to_delivery_seconds,

    /* Late delivery flag */
    CASE
        WHEN o.order_delivered_customer_date REGEXP
                 '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
         AND o.order_estimated_delivery_date REGEXP
                 '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        THEN
            STR_TO_DATE(o.order_delivered_customer_date, '%Y-%m-%d %H:%i:%s')
            >
            STR_TO_DATE(o.order_estimated_delivery_date, '%Y-%m-%d %H:%i:%s')
        ELSE NULL
    END AS is_late_delivery

FROM olist_raw.order_items oi
INNER JOIN olist_raw.orders o
    ON o.order_id = oi.order_id

WHERE oi.price REGEXP '^[0-9]+(\\.[0-9]+)?$'
  AND CAST(oi.price AS DECIMAL(12,2)) > 0
  AND oi.freight_value REGEXP '^[0-9]+(\\.[0-9]+)?$'
  AND CAST(oi.freight_value AS DECIMAL(12,2)) >= 0;

-- Note: purchase_to_delivery is stored in SECONDS (purchase_to_delivery_seconds)
-- rather than as a Postgres INTERVAL, since MySQL has no interval column
-- type. Divide by 86400 for days in your analysis queries, e.g.:
--   purchase_to_delivery_seconds / 86400 AS days_to_deliver

ALTER TABLE olist_clean.fact_order_items
    ADD INDEX idx_fact_order_items_order       (order_id),
    ADD INDEX idx_fact_order_items_customer    (customer_id),
    ADD INDEX idx_fact_order_items_seller      (seller_id),
    ADD INDEX idx_fact_order_items_product     (product_id),
    ADD INDEX idx_fact_order_items_purchdate   (order_purchase_date);

-- ---------------------------------------------------------------------------
-- fact_order_payments: kept as its own fact (different grain — payments per
-- order, not per item) rather than joined into fact_order_items, which
-- would multiply payment rows across items and double-count payment_value.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.fact_order_payments;
CREATE TABLE olist_clean.fact_order_payments AS
SELECT
    op.order_id,
    CAST(op.payment_sequential AS UNSIGNED)  AS payment_sequential,
    op.payment_type,
    CAST(op.payment_installments AS UNSIGNED) AS payment_installments,
    CAST(op.payment_value AS DECIMAL(12,2))   AS payment_value
FROM olist_raw.order_payments op
WHERE op.payment_value REGEXP '^[0-9]+(\\.[0-9]+)?$';

ALTER TABLE olist_clean.fact_order_payments
    ADD INDEX idx_fact_payments_order (order_id);

-- ---------------------------------------------------------------------------
-- dim_geolocation: one row per zip prefix.
-- MySQL has no PERCENTILE_CONT and no MODE() aggregate, so median lat/lng
-- and the "most common" city/state are built manually with window
-- functions — this is the standard MySQL 8 pattern for both.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS olist_clean.dim_geolocation;

CREATE TABLE olist_clean.dim_geolocation (
    zip_prefix INT PRIMARY KEY,
    lat        DECIMAL(10,6),
    lng        DECIMAL(10,6),
    city       VARCHAR(128),
    state      VARCHAR(8)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO olist_clean.dim_geolocation
WITH lat_ranked AS (
    SELECT
        CAST(geolocation_zip_code_prefix AS UNSIGNED) AS zip_prefix,
        CAST(geolocation_lat AS DECIMAL(10,6))          AS lat,
        ROW_NUMBER() OVER (PARTITION BY geolocation_zip_code_prefix ORDER BY geolocation_lat) AS rn,
        COUNT(*)     OVER (PARTITION BY geolocation_zip_code_prefix) AS cnt
    FROM olist_raw.geolocation
),
lat_median AS (
    SELECT zip_prefix, AVG(lat) AS lat
    FROM lat_ranked
    WHERE rn IN (FLOOR((cnt + 1) / 2), CEIL((cnt + 1) / 2))
    GROUP BY zip_prefix
),
lng_ranked AS (
    SELECT
        CAST(geolocation_zip_code_prefix AS UNSIGNED) AS zip_prefix,
        CAST(geolocation_lng AS DECIMAL(10,6))          AS lng,
        ROW_NUMBER() OVER (PARTITION BY geolocation_zip_code_prefix ORDER BY geolocation_lng) AS rn,
        COUNT(*)     OVER (PARTITION BY geolocation_zip_code_prefix) AS cnt
    FROM olist_raw.geolocation
),
lng_median AS (
    SELECT zip_prefix, AVG(lng) AS lng
    FROM lng_ranked
    WHERE rn IN (FLOOR((cnt + 1) / 2), CEIL((cnt + 1) / 2))
    GROUP BY zip_prefix
),
city_mode AS (
    SELECT zip_prefix, city FROM (
        SELECT
            CAST(geolocation_zip_code_prefix AS UNSIGNED) AS zip_prefix,
            geolocation_city AS city,
            ROW_NUMBER() OVER (
                PARTITION BY geolocation_zip_code_prefix
                ORDER BY COUNT(*) DESC
            ) AS rn
        FROM olist_raw.geolocation
        GROUP BY geolocation_zip_code_prefix, geolocation_city
    ) ranked_city
    WHERE rn = 1
),
state_mode AS (
    SELECT zip_prefix, state FROM (
        SELECT
            CAST(geolocation_zip_code_prefix AS UNSIGNED) AS zip_prefix,
            geolocation_state AS state,
            ROW_NUMBER() OVER (
                PARTITION BY geolocation_zip_code_prefix
                ORDER BY COUNT(*) DESC
            ) AS rn
        FROM olist_raw.geolocation
        GROUP BY geolocation_zip_code_prefix, geolocation_state
    ) ranked_state
    WHERE rn = 1
)
SELECT
    lm.zip_prefix,
    lm.lat,
    ln.lng,
    cm.city,
    sm.state
FROM lat_median lm
JOIN lng_median ln ON ln.zip_prefix = lm.zip_prefix
JOIN city_mode  cm ON cm.zip_prefix = lm.zip_prefix
JOIN state_mode sm ON sm.zip_prefix = lm.zip_prefix;

-- ---------------------------------------------------------------------------
-- Post-build row-count sanity check
-- ---------------------------------------------------------------------------
SELECT 'dim_date' AS table_name, COUNT(*) AS row_count FROM olist_clean.dim_date
UNION ALL SELECT 'dim_customers',       COUNT(*) FROM olist_clean.dim_customers
UNION ALL SELECT 'dim_sellers',         COUNT(*) FROM olist_clean.dim_sellers
UNION ALL SELECT 'dim_products',        COUNT(*) FROM olist_clean.dim_products
UNION ALL SELECT 'dim_reviews',         COUNT(*) FROM olist_clean.dim_reviews
UNION ALL SELECT 'dim_geolocation',     COUNT(*) FROM olist_clean.dim_geolocation
UNION ALL SELECT 'fact_order_items',    COUNT(*) FROM olist_clean.fact_order_items
UNION ALL SELECT 'fact_order_payments', COUNT(*) FROM olist_clean.fact_order_payments
ORDER BY 1;
