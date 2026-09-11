-- ============================================================================
-- 05_payments_analysis.sql   (MySQL 8.0+)
-- Phase 2: Payment method and installment behavior.
-- Uses fact_order_payments — a different grain from fact_order_items (see
-- the payments-vs-items grain discussion in the Phase 1 README). None of
-- these queries join payments to items directly for that reason.
-- ============================================================================

USE olist_clean;

-- ---------------------------------------------------------------------------
-- 5.1 Payment type distribution
-- ---------------------------------------------------------------------------
SELECT
    payment_type,
    COUNT(*)                       AS n_payments,
    ROUND(AVG(payment_value), 2)   AS avg_payment_value,
    ROUND(AVG(payment_installments), 1) AS avg_installments
FROM fact_order_payments
GROUP BY payment_type
ORDER BY n_payments DESC;

-- ---------------------------------------------------------------------------
-- 5.2 Average order value by primary payment method
-- An order can have multiple payment rows (split payments); "primary"
-- here means the payment_type with the largest single payment_value on
-- that order.
-- ---------------------------------------------------------------------------
WITH order_payment_summary AS (
    SELECT
        order_id,
        SUM(payment_value) AS order_total_paid,
        SUBSTRING_INDEX(GROUP_CONCAT(payment_type ORDER BY payment_value DESC), ',', 1) AS primary_payment_type
    FROM fact_order_payments
    GROUP BY order_id
)
SELECT
    primary_payment_type,
    COUNT(*)                        AS n_orders,
    ROUND(AVG(order_total_paid), 2) AS avg_order_value
FROM order_payment_summary
GROUP BY primary_payment_type
ORDER BY n_orders DESC;

-- ---------------------------------------------------------------------------
-- 5.3 Installment count distribution (credit card payments mostly)
-- ---------------------------------------------------------------------------
SELECT
    payment_installments,
    COUNT(*) AS n_payments
FROM fact_order_payments
WHERE payment_type = 'credit_card'
GROUP BY payment_installments
ORDER BY payment_installments;
