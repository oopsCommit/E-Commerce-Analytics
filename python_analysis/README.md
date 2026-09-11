# Phase 3 — Python (Statistics, NLP, Clustering, Forecasting)

Everything here pulls from `olist_clean` via SQLAlchemy — no re-cleaning in pandas, since Phase 1 already did that. Python's job is strictly the analysis SQL can't do: significance testing, text classification, unsupervised clustering, and time-series forecasting.

## Files

| File | What it does | Writes to MySQL |
|---|---|---|
| `00_db_connection.py` | Shared connection helper — import from this, don't duplicate connection strings | — |
| `01_statistical_tests.py` | t-test (on-time vs. late delivery → review score), chi-square (payment type → review score, customer state → late-delivery rate) | `py_statistical_test_results` |
| `02_sentiment_nlp.py` | Sentiment analysis on pt-BR review text (transformer or lexicon approach), top complaint keywords | `py_review_sentiment`, `py_negative_review_keywords` |
| `03_clustering.py` | k-means on RFM features (validates Phase 2's SQL segments) + product clustering (price/freight/weight/review) | `py_customer_clusters`, `py_product_clusters` |
| `04_forecasting.py` | Stretch goal — Prophet weekly revenue forecast, clearly labeled illustrative | `py_revenue_forecast` |

## Setup

```bash
cd python/
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

Set your DB credentials as environment variables rather than hardcoding them (see `00_db_connection.py`):

```bash
export OLIST_DB_USER=root
export OLIST_DB_PASSWORD=yourpassword
export OLIST_DB_HOST=localhost
export OLIST_DB_NAME=olist_clean
```

## Run order

```bash
python 01_statistical_tests.py
python 02_sentiment_nlp.py --approach lexicon        # or --approach transformer
python 03_clustering.py
python 04_forecasting.py                              # optional stretch goal
```

Each script is independent (all read from `olist_clean`, none depend on another script's output), so run them in any order — the list above is just the order they're discussed in the plan.

## Design choices worth explaining in your write-up

- **Welch's t-test, not Student's** (`01_statistical_tests.py`), since it doesn't assume the on-time and late groups have equal variance — a safer default when you haven't checked that assumption.
- **Effect size reported alongside p-value.** With ~100k rows, almost anything comes back statistically significant (p < 0.05) even when the actual difference is tiny and not business-relevant. The script prints both the p-value and the raw mean/percentage gap deliberately — report both, not just "it's significant."
- **Portuguese-aware NLP, not an English default.** The sentiment script explicitly calls out that most NLP tutorials assume English and gives two working pt-BR approaches (a multilingual transformer, or a lightweight PT lexicon) rather than silently running an English sentiment tool on Portuguese text.
- **k chosen via silhouette score, not guessed.** Both clustering routines try k=2 through 7 (or 8) and report the silhouette score for each, picking the best rather than hardcoding "k=4" without justification.
- **Log-transforming skewed features before clustering.** Monetary value and order frequency are heavily right-skewed (a few customers spend far more than most) — clustering on raw values would let those outliers dominate the distance calculation; log-transforming first fixes that.
- **Forecasting is explicitly labeled illustrative.** The dataset ends in 2018, so `04_forecasting.py`'s output is a demonstration of technique, not a real prediction — say this out loud in the dashboard/README, don't let it look like a live forecast.

## What's NOT done here (by design)

- No re-cleaning of raw data — that's Phase 1's job, already done in SQL.
- No descriptive aggregation that SQL already covers (revenue trends, AOV, etc.) — that's Phase 2. Python here only does what SQL structurally can't: p-values, text classification, clustering, forecasting.

## Next: Phase 4

All five `py_*` tables written here live in `olist_clean` alongside the Phase 1/2 tables — Power BI connects to one MySQL database and sees SQL-native and Python-derived tables as one unified model, not two separate sources to reconcile.
