-- ============================================================================
-- 05_add_dim_orders_bridge.sql   (MySQL 8.0+)
-- Adds a small bridge table so fact_order_items and fact_order_payments can
-- be related in Power BI without a many-to-many relationship.
--
-- WHY THIS IS NEEDED: order_id is not unique in either fact table (multiple
-- items per order, multiple payment installments per order), so there's no
-- natural "one" side to anchor a one-to-many relationship on between them
-- directly. Power BI's Model view will offer to create the relationship as
-- Many-to-many with Both-direction cross-filtering if you try — accepting
-- that is risky: it's easy to get silently double-counted or ambiguous
-- totals the first time a visual pulls measures from both fact tables.
--
-- THE FIX: relate each fact table to this bridge table instead (both as
-- ordinary many-to-one relationships), never to each other directly.
-- Run this after 04_build_dimensions_and_facts.sql.
-- ============================================================================

USE olist_clean;

SET SESSION collation_connection = utf8mb4_unicode_ci;

DROP TABLE IF EXISTS olist_clean.dim_orders;

CREATE TABLE olist_clean.dim_orders AS
SELECT order_id FROM olist_clean.fact_order_items
UNION
SELECT order_id FROM olist_clean.fact_order_payments;

-- Same collation fix as every other table in this schema (see
-- 00_fix_collation.sql) — belt and suspenders so this new table can't
-- reintroduce Error 1267 against the tables it's about to be joined to.
ALTER TABLE olist_clean.dim_orders CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE olist_clean.dim_orders
    MODIFY order_id VARCHAR(64) NOT NULL,
    ADD PRIMARY KEY (order_id);

SELECT COUNT(*) AS n_orders FROM olist_clean.dim_orders;
-- Sanity check: this count should equal (or very slightly exceed, if any
-- payment rows reference an order_id fact_order_items doesn't have) the
-- distinct order_id count in fact_order_items alone. A big gap between
-- the two would be worth investigating before trusting the bridge.
