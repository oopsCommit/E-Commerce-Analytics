"""
04_forecasting.py
Phase 3 stretch goal: a simple monthly revenue forecast using Prophet.

HONESTY CHECKPOINT before you build this into the portfolio: the dataset
ends in late 2018, so any forecast this produces is illustrative of the
*technique*, not a real prediction of anything — say so explicitly
wherever this shows up (README, dashboard, case study). Presenting it as
a live forecast would be misleading; presenting it as "here's how I'd
forecast revenue if this were a live business" is the honest and still
portfolio-worthy framing.

Run: python 04_forecasting.py
Writes: olist_clean.py_revenue_forecast
"""
import pandas as pd
from db_connection import get_engine

engine = get_engine()


def main():
    query = """
        SELECT
            d.date_key AS ds,
            SUM(f.item_price) AS y
        FROM olist_clean.fact_order_items f
        JOIN olist_clean.dim_date d ON d.date_key = f.order_purchase_date
        WHERE f.order_status = 'delivered'
        GROUP BY d.date_key
        ORDER BY d.date_key
    """
    df = pd.read_sql(query, engine, parse_dates=["ds"])
    print(f"Loaded {len(df)} days of revenue history "
          f"({df['ds'].min().date()} to {df['ds'].max().date()}).")

    # Daily revenue is noisy (weekday/weekend swings, occasional promo
    # spikes) — resample to weekly to give Prophet a cleaner signal, since
    # this dataset doesn't span enough years for it to learn a reliable
    # yearly seasonality pattern from daily data alone.
    df_weekly = df.set_index("ds").resample("W").sum().reset_index()

    try:
        from prophet import Prophet
    except ImportError:
        print("\nProphet isn't installed. Install with:")
        print("  pip install prophet --break-system-packages")
        print("(Prophet has heavier build dependencies than the rest of this")
        print("project — if it's causing install friction, statsmodels' ")
        print("SARIMAX or a simple moving-average baseline are lighter")
        print("fallbacks worth documenting as an alternative in your README.)")
        return

    model = Prophet(weekly_seasonality=False, yearly_seasonality=True, daily_seasonality=False)
    model.fit(df_weekly)

    future = model.make_future_dataframe(periods=12, freq="W")  # 12 weeks ahead
    forecast = model.predict(future)

    out = forecast[["ds", "yhat", "yhat_lower", "yhat_upper"]].copy()
    out["is_forecast"] = out["ds"] > df_weekly["ds"].max()
    out.to_sql("py_revenue_forecast", engine, schema="olist_clean", if_exists="replace", index=False)

    print(f"\nWrote {len(out)} rows to olist_clean.py_revenue_forecast "
          f"({out['is_forecast'].sum()} are forward-looking forecast weeks).")
    print("\nReminder: label this in the dashboard as an illustrative")
    print("technique demo, not a live forecast — the underlying data stops")
    print("in 2018.")


if __name__ == "__main__":
    main()
