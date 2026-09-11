-- ============================================================================
-- 01_create_staging_schema.sql   (MySQL 8.0+)
-- Phase 1, Step 1: Create raw staging database + tables.
-- Columns match the Kaggle CSVs exactly (no cleaning/typing decisions yet) —
-- this preserves an untouched source of truth we can always re-derive from.
--
-- NOTE ON "SCHEMA" IN MYSQL: unlike Postgres (where a schema is a namespace
-- inside one database), in MySQL CREATE SCHEMA is just a synonym for
-- CREATE DATABASE. So olist_raw and olist_clean (Phase 1 Step 4) will be
-- two separate databases, not two schemas inside one. Cross-database joins
-- just use db.table — same as Postgres schema.table — so nothing else
-- about the model changes.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS olist_raw
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE olist_raw;

-- ---------------------------------------------------------------------------
-- Customers: one row per (order-level) customer_id.
-- customer_unique_id is the REAL person; customer_id is per-order.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS customers;
CREATE TABLE customers (
    customer_id                VARCHAR(64),
    customer_unique_id         VARCHAR(64),
    customer_zip_code_prefix   VARCHAR(16),
    customer_city               VARCHAR(128),
    customer_state               VARCHAR(8)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Geolocation: many rows per zip prefix (multiple lat/lng samples) — this is
-- a raw sample table, not a clean 1-row-per-zip dimension. We'll dedupe later.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS geolocation;
CREATE TABLE geolocation (
    geolocation_zip_code_prefix VARCHAR(16),
    geolocation_lat              VARCHAR(32),
    geolocation_lng              VARCHAR(32),
    geolocation_city             VARCHAR(128),
    geolocation_state            VARCHAR(8)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Order items: grain = 1 row per item within an order.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS order_items;
CREATE TABLE order_items (
    order_id             VARCHAR(64),
    order_item_id         VARCHAR(16),
    product_id            VARCHAR(64),
    seller_id             VARCHAR(64),
    shipping_limit_date   VARCHAR(32),
    price                 VARCHAR(32),
    freight_value         VARCHAR(32)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Payments: an order can have multiple payment rows (installments / split
-- payment types), so grain = 1 row per payment "sequence" on an order.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS order_payments;
CREATE TABLE order_payments (
    order_id              VARCHAR(64),
    payment_sequential     VARCHAR(16),
    payment_type           VARCHAR(32),
    payment_installments   VARCHAR(16),
    payment_value           VARCHAR(32)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Reviews: 1 row per review (an order can technically have >1 review in the
-- raw data — we'll dedupe to latest review per order in the clean layer).
-- comment_message needs real TEXT — some reviews run long.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS order_reviews;
CREATE TABLE order_reviews (
    review_id                  VARCHAR(64),
    order_id                   VARCHAR(64),
    review_score                 VARCHAR(8),
    review_comment_title         VARCHAR(255),
    review_comment_message       TEXT,
    review_creation_date         VARCHAR(32),
    review_answer_timestamp      VARCHAR(32)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Orders: grain = 1 row per order.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    order_id                       VARCHAR(64),
    customer_id                    VARCHAR(64),
    order_status                   VARCHAR(32),
    order_purchase_timestamp        VARCHAR(32),
    order_approved_at               VARCHAR(32),
    order_delivered_carrier_date    VARCHAR(32),
    order_delivered_customer_date   VARCHAR(32),
    order_estimated_delivery_date   VARCHAR(32)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Products: grain = 1 row per product. Note the misspelled "lenght" columns
-- — that's how Olist shipped it; we keep raw names here, fix on load into
-- the clean layer.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS products;
CREATE TABLE products (
    product_id                    VARCHAR(64),
    product_category_name          VARCHAR(128),
    product_name_lenght             VARCHAR(16),
    product_description_lenght      VARCHAR(16),
    product_photos_qty              VARCHAR(16),
    product_weight_g                VARCHAR(16),
    product_length_cm               VARCHAR(16),
    product_height_cm               VARCHAR(16),
    product_width_cm                VARCHAR(16)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Sellers: grain = 1 row per seller.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS sellers;
CREATE TABLE sellers (
    seller_id                 VARCHAR(64),
    seller_zip_code_prefix     VARCHAR(16),
    seller_city                 VARCHAR(128),
    seller_state                 VARCHAR(8)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Category name translation (PT -> EN).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS category_translation;
CREATE TABLE category_translation (
    product_category_name           VARCHAR(128),
    product_category_name_english     VARCHAR(128)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Notes:
-- * Every column is loaded as VARCHAR/TEXT on purpose. Typing/casting
--   happens deliberately in the clean layer (03_data_quality_checks.sql and
--   04_build_dimensions_and_facts.sql) so bad values are visible in step 3
--   instead of silently truncated or coerced on load.
-- * utf8mb4 is required, not plain utf8 — Portuguese review text (accents,
--   ç, ã, õ) and any emoji in review comments need the full 4-byte charset.
