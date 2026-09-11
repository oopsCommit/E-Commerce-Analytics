-- ============================================================================
-- 02_load_staging_data.sql   (MySQL 8.0+)
-- Phase 1, Step 2: Bulk-load the Kaggle CSVs into olist_raw.*
--
-- HOW TO USE
-- 1. Download the dataset from Kaggle:
--    https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
-- 2. Unzip all 9 CSVs into a single folder, e.g. /data/olist/
-- 3. Edit the file paths below to match where you put them.
-- 4. LOCAL INFILE must be enabled on BOTH sides:
--      - server:  SET GLOBAL local_infile = 1;
--      - client:  connect with --local-infile=1
--        (Workbench: Edit > Preferences > SQL Editor > "Allow loading local
--        infile", or in CLI: mysql --local-infile=1 -u root -p olist_raw)
--    If you're on a managed host (RDS, PlanetScale, etc.) that blocks
--    LOCAL INFILE entirely, load the CSVs into the server's accessible
--    storage and use LOAD DATA INFILE (no LOCAL) with a server-side path
--    instead, or fall back to a script-based loader (Python + pandas.to_sql,
--    or the client's native CSV-import GUI).
-- ============================================================================

USE olist_raw;

SET FOREIGN_KEY_CHECKS = 0;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_customers_dataset.csv'
INTO TABLE customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_geolocation_dataset.csv'
INTO TABLE geolocation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_order_items_dataset.csv'
INTO TABLE order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_order_payments_dataset.csv'
INTO TABLE order_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- Reviews need LINES TERMINATED BY handled carefully — some review comments
-- contain embedded newlines within quoted fields. MySQL's LOAD DATA handles
-- quoted embedded newlines correctly as long as OPTIONALLY ENCLOSED BY '"'
-- is set (it is, below) — do not strip the quoting on this file.
LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_order_reviews_dataset.csv'
INTO TABLE order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_orders_dataset.csv'
INTO TABLE orders
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_products_dataset.csv'
INTO TABLE products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/olist_sellers_dataset.csv'
INTO TABLE sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'C:/Users/singh/Desktop/olist_project/product_category_name_translation.csv'
INTO TABLE category_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

SET FOREIGN_KEY_CHECKS = 1;

-- Sanity check row counts immediately after load. Expected approx values
-- (from the published dataset) are in comments — flag anything wildly off.
SELECT 'customers'           AS table_name, COUNT(*) AS row_count FROM customers            -- ~99,441
UNION ALL SELECT 'geolocation',            COUNT(*) FROM geolocation                          -- ~1,000,000+
UNION ALL SELECT 'order_items',            COUNT(*) FROM order_items                          -- ~112,650
UNION ALL SELECT 'order_payments',         COUNT(*) FROM order_payments                       -- ~103,886
UNION ALL SELECT 'order_reviews',          COUNT(*) FROM order_reviews                        -- ~99,224
UNION ALL SELECT 'orders',                 COUNT(*) FROM orders                               -- ~99,441
UNION ALL SELECT 'products',               COUNT(*) FROM products                             -- ~32,951
UNION ALL SELECT 'sellers',                COUNT(*) FROM sellers                               -- ~3,095
UNION ALL SELECT 'category_translation',   COUNT(*) FROM category_translation                -- ~71
ORDER BY 1;

-- If "The used command is not allowed with this MySQL version" appears:
-- your client was connected without --local-infile=1, or the server has
-- local_infile OFF and you don't have SUPER to change it live — ask your
-- DBA / hosting provider, or switch to a server-side LOAD DATA INFILE path.
