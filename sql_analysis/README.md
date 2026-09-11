# Phase 1 — Data Engineering in SQL (MySQL 8.0+)

Turns the 9 raw Olist CSVs into a clean, query-ready star-schema model in MySQL.

## Files (run in this order)

| # | File | What it does |
|---|------|---------------|
| 1 | `01_create_staging_schema.sql` | Creates the `olist_raw` database + 9 staging tables, all columns as VARCHAR/TEXT |
| 2 | `02_load_staging_data.sql` | Bulk-loads the CSVs via `LOAD DATA LOCAL INFILE`; prints row counts to sanity-check the load |
| 3 | `03_data_quality_checks.sql` | 12 diagnostic queries — duplicates, orphaned FKs, bad values, timestamp logic errors, missing category translations |
| 4 | `04_build_dimensions_and_facts.sql` | Builds the `olist_clean` database: `dim_date`, `dim_customers`, `dim_sellers`, `dim_products`, `dim_reviews`, `dim_geolocation`, `fact_order_items`, `fact_order_payments` |


## How to run

```bash
# 1. Download & unzip the dataset from Kaggle into /data/olist/
#    https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

# 2. Enable local_infile server-side (one-time, or add to my.cnf)
mysql -u root -p -e "SET GLOBAL local_infile = 1;"

# 3. Run each script in order, connecting WITH --local-infile=1
mysql --local-infile=1 -u root -p < 01_create_staging_schema.sql
mysql --local-infile=1 -u root -p < 02_load_staging_data.sql   # edit file paths first if not /data/olist
mysql --local-infile=1 -u root -p < 03_data_quality_checks.sql # review output — see findings log below
mysql --local-infile=1 -u root -p < 04_build_dimensions_and_facts.sql
```

If you're using MySQL Workbench instead of the CLI: enable "Allow loading local infile" under Edit > Preferences > SQL Editor before running step 2, and run each `.sql` file as a script (not pasted query-by-query, since a few statements depend on session settings).

## Design decisions worth calling out in your write-up

- **Raw layer stays untyped (VARCHAR/TEXT).** Casting happens deliberately in the clean layer so bad values are visible in step 3 rather than silently truncated or coerced on load.
- **`fact_order_items` is `INNER JOIN`, not `LEFT JOIN`, to `orders`.** Orphaned order_items (no matching order) are excluded — see data-quality finding #2. Document the excluded row count in your README.
- **Reviews deduped to one per order** (latest by `review_answer_timestamp`) — the raw data allows multiple; the clean layer picks the most recent as the "official" review.
- **`fact_order_payments` is a separate fact table**, not merged into `fact_order_items` — different grain (per-payment vs. per-item). Joining them would multiply and double-count `payment_value`.
- **`customer_id` vs `customer_unique_id`** — `dim_customers` keeps `customer_id` as the grain (matches the fact table FK) but carries `customer_unique_id` for any repeat-purchase/retention logic in Phase 2. Getting this wrong is the single most common mistake with this dataset.
- **Geolocation is aggregated to one row per zip prefix** using the true median lat/lng (via window functions, since MySQL has no `PERCENTILE_CONT`) across all raw samples.

## Known data quality findings (fill in after you run step 3)

Run `03_data_quality_checks.sql` against your own load and record actual counts here — this becomes a legitimate, portfolio-worthy "data quality log" section:

- Duplicate `order_id`s in orders: **\_\_\_**
- Orphaned order_items (no matching order): **\_\_\_**
- Orders with no items: **\_\_\_** (mostly `order_status = 'canceled'` — expected)
- Invalid price/freight rows excluded: **\_\_\_**
- Orders with >1 review: **\_\_\_**
- Product categories missing an English translation: **\_\_\_**


