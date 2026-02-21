"""
Real Estate Serbia — Airflow DAG
=================================
Runs both scrapers daily at 03:00 AM.

Task order:
    scrape_nekretnine → scrape_oglasi → validate_data
"""

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
import psycopg2
import os

# --- DAG DEFAULT ARGUMENTS ---
# These apply to all tasks unless overridden individually

default_args = {
    'owner': 'real_estate',
    'retries': 2,                           # retry failed task 2 times
    'retry_delay': timedelta(minutes=5),    # wait 5 min between retries
    'email_on_failure': False,
}

# --- DAG DEFINITION ---

with DAG(
    dag_id='real_estate_serbia',
    default_args=default_args,
    description='Daily scraping of nekretnine.rs and oglasi.rs',
    schedule_interval='0 3 * * *',          # every day at 03:00 AM
    start_date=datetime(2026, 1, 1),
    catchup=False,                          # don't backfill missed runs
    tags=['real_estate', 'scraping'],
) as dag:

    # --- TASK 1: scrape nekretnine.rs ---
    scrape_nekretnine = BashOperator(
        task_id='scrape_nekretnine',
        bash_command='python /opt/airflow/scrapers/nekretnine_rs.py',
    )

    # --- TASK 2: scrape oglasi.rs ---
    scrape_oglasi = BashOperator(
        task_id='scrape_oglasi',
        bash_command='python /opt/airflow/scrapers/oglasi_rs_scraper.py',
    )

    # --- TASK 3: validate SCD integrity ---
    def validate_data():
        """
        Runs validate_scd_integrity() SQL function.
        Raises exception if any issues found — this fails the DAG task.
        """
        conn = psycopg2.connect(
            host=os.environ.get('DB_HOST', 'postgres'),
            port=os.environ.get('DB_PORT', '5432'),
            database=os.environ.get('DB_NAME', 'real_estate'),
            user=os.environ.get('DB_USER', 'postgres'),
            password=os.environ.get('DB_PASSWORD', 'postgres123')
        )
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM validate_scd_integrity();")
        issues = cursor.fetchall()
        cursor.close()
        conn.close()

        if issues:
            raise ValueError(f"SCD integrity issues found: {issues}")

        print("✅ SCD validation passed — no integrity issues.")

    validate = PythonOperator(
        task_id='validate_data',
        python_callable=validate_data,
    )

    # --- TASK ORDER ---
    # nekretnine must finish before oglasi starts
    # validation runs only after both scrapers complete
    scrape_nekretnine >> scrape_oglasi >> validate