"""
00_db_connection.py
Shared MySQL connection helper for every Phase 3 script. Import from here
rather than duplicating connection strings in each file.

SECURITY NOTE: don't hardcode a real password in this file if the repo is
public. Read from an environment variable (shown below) or a local
.env file excluded via .gitignore.
"""
import os
from sqlalchemy import create_engine


DB_USER = os.environ.get("OLIST_DB_USER", "root")
DB_PASSWORD = os.environ.get("OLIST_DB_PASSWORD", "jittery")
DB_HOST = os.environ.get("OLIST_DB_HOST", "localhost")
DB_PORT = os.environ.get("OLIST_DB_PORT", "3306")
DB_NAME = os.environ.get("OLIST_DB_NAME", "olist_clean")


def get_engine():
    """
    Returns a SQLAlchemy engine connected to olist_clean via PyMySQL.
    Usage:
        from db_connection import get_engine
        import pandas as pd
        engine = get_engine()
        df = pd.read_sql("SELECT * FROM fact_order_items LIMIT 100", engine)
    """
    url = f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}?charset=utf8mb4"
    return create_engine(url, pool_pre_ping=True)


if __name__ == "__main__":
    # Quick connectivity check: python 00_db_connection.py
    engine = get_engine()
    with engine.connect() as conn:
        from sqlalchemy import text
        result = conn.execute(text("SELECT COUNT(*) FROM fact_order_items"))
        print("fact_order_items row count:", result.scalar())
