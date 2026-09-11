-- ============================================================================
-- 03_customer_behavior.sql   (MySQL 8.0+)
-- Phase 2: Repeat-purchase rate, RFM segmentation, cohort retention.
--
-- IMPORTANT: every query here uses customer_unique_id, not customer_id.
-- customer_id is generated fresh per order in this dataset — joining or
-- grouping on customer_id instead would make every customer look like a
-- one-time buyer, silently zeroing out repeat-purchase analysis. This is
-- the single most common mistake with this specific dataset.
--
-- KNOWN DATASET CHARACTERISTIC: Olist's real repeat-purchase rate is low
-- (commonly cited around 3%). If your numbers come back similarly low,
-- that's the data, not a query bug — don't "fix" it by loosening the
-- customer_unique_id join.
-- ============================================================================

USE olist_clean;

-- ---------------------------------------------------------------------------
-- 3.1 Repeat-purchase rate
-- ---------------------------------------------------------------------------
WITH cust_orders AS (
    SELECT c.customer_unique_id, COUNT(DISTINCT f.order_id) AS n_orders
    FROM fact_order_items f
    JOIN dim_customers c ON c.customer_id = f.customer_id
    WHERE f.order_status = 'delivered'
    GROUP BY c.customer_unique_id
)
SELECT
    COUNT(*)                                                              AS total_customers,
    SUM(CASE WHEN n_orders > 1 THEN 1 ELSE 0 END)                          AS repeat_customers,
    ROUND(SUM(CASE WHEN n_orders > 1 THEN 1 ELSE 0 END) / COUNT(*) * 100, 2) AS repeat_rate_pct
FROM cust_orders;

-- ---------------------------------------------------------------------------
-- 3.2 RFM segmentation
-- Recency = days since last order (relative to a snapshot date = 1 day
-- after the most recent order in the dataset, so "today" is well-defined
-- for a historical dataset that stops in 2018).
-- Frequency = distinct delivered orders. Monetary = total item spend.
-- ---------------------------------------------------------------------------
WITH cust_orders AS (
    SELECT
        c.customer_unique_id,
        MAX(f.order_purchase_ts)   AS last_purchase_ts,
        COUNT(DISTINCT f.order_id) AS frequency,
        SUM(f.item_price)          AS monetary
    FROM fact_order_items f
    JOIN dim_customers c ON c.customer_id = f.customer_id
    WHERE f.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
snapshot AS (
    SELECT DATE_ADD(MAX(order_purchase_ts), INTERVAL 1 DAY) AS snapshot_date
    FROM fact_order_items
    WHERE order_status = 'delivered'
),
rfm_base AS (
    SELECT
        co.customer_unique_id,
        TIMESTAMPDIFF(DAY, co.last_purchase_ts, s.snapshot_date) AS recency_days,
        co.frequency,
        co.monetary
    FROM cust_orders co
    CROSS JOIN snapshot s
),
rfm_scored AS (
    SELECT
        *,
        -- tile 5 = best in every case: most recent, most frequent, highest spend
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score,
        NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_base
)
SELECT
    customer_unique_id, recency_days, frequency, monetary,
    r_score, f_score, m_score, (r_score + f_score + m_score) AS rfm_total,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        WHEN r_score >= 4 AND f_score <= 2                  THEN 'New / Promising'
        WHEN r_score <= 2 AND f_score >= 4                  THEN 'At Risk (was loyal)'
        WHEN r_score <= 2 AND f_score <= 2                  THEN 'Lost'
        ELSE 'Regular'
    END AS rfm_segment
FROM rfm_scored;

-- CAVEAT worth stating in your write-up: because most customers in this
-- dataset are one-time buyers, the "frequency" NTILE is heavily tied at
-- the low end (most rows = 1 order). NTILE still splits ties arbitrarily
-- across buckets, so f_score differences among one-time buyers reflect
-- ORDER of evaluation, not a real behavioral difference. Treat f_score as
-- meaningful mainly for the minority of customers with frequency > 1;
-- Phase 3's k-means clustering (03_clustering.py) is a better lens on
-- this same data for that reason.

-- ---------------------------------------------------------------------------
-- 3.3 Cohort retention: group customers by first-purchase month, track
-- what % of that cohort is still ordering in each subsequent month.
-- ---------------------------------------------------------------------------
WITH first_purchase AS (
    SELECT
        c.customer_unique_id,
        DATE_FORMAT(MIN(f.order_purchase_ts), '%Y-%m-01') AS cohort_month
    FROM fact_order_items f
    JOIN dim_customers c ON c.customer_id = f.customer_id
    WHERE f.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
orders_with_cohort AS (
    SELECT DISTINCT
        c.customer_unique_id,
        fp.cohort_month,
        DATE_FORMAT(f.order_purchase_ts, '%Y-%m-01') AS order_month
    FROM fact_order_items f
    JOIN dim_customers c ON c.customer_id = f.customer_id
    JOIN first_purchase fp ON fp.customer_unique_id = c.customer_unique_id
    WHERE f.order_status = 'delivered'
),
cohort_activity AS (
    SELECT
        cohort_month,
        order_month,
        PERIOD_DIFF(DATE_FORMAT(order_month, '%Y%m'), DATE_FORMAT(cohort_month, '%Y%m')) AS month_number,
        COUNT(DISTINCT customer_unique_id) AS active_customers
    FROM orders_with_cohort
    GROUP BY cohort_month, order_month
),
cohort_size AS (
    SELECT cohort_month, COUNT(DISTINCT customer_unique_id) AS cohort_customers
    FROM first_purchase
    GROUP BY cohort_month
)
SELECT
    ca.cohort_month, ca.month_number, ca.active_customers, cs.cohort_customers,
    ROUND(ca.active_customers / cs.cohort_customers * 100, 2) AS retention_pct
FROM cohort_activity ca
JOIN cohort_size cs ON cs.cohort_month = ca.cohort_month
ORDER BY ca.cohort_month, ca.month_number;

-- Expect month_number = 0 to show 100% for every cohort (that's the
-- definition — everyone in a cohort ordered in their own first month) and
-- retention to fall off steeply afterward, consistent with the low
-- repeat-purchase rate from 3.1. A cohort chart that looks "too good" past
-- month 1 is more likely a customer_id/customer_unique_id mixup than a
-- real result — worth a gut-check against 3.1's repeat rate before trusting it.
