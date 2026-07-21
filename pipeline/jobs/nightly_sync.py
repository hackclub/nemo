import subprocess
from datetime import date, timedelta
from pathlib import Path

from dotenv import load_dotenv

from ingest.analytics_pull import pull_channel_day, pull_member_day, pull_users
from ingest.autojoin import join_all
from lib.db import connect, finish_run, start_run
from lib.slack_client import bot_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
DBT_DIR = Path(__file__).resolve().parents[2] / "dbt"
SOURCE = "nightly_sync"


def run_dbt():
    subprocess.run(["dbt", "run", "--profiles-dir", str(DBT_DIR)], cwd=DBT_DIR, check=True)


def main():
    load_dotenv(ENV_FILE)
    pull_date = date.today() - timedelta(days=2)
    with connect() as conn:
        run_id = start_run(conn, SOURCE)
        conn.commit()
        try:
            pull_member_day(conn, pull_date)
            pull_channel_day(conn, pull_date)
            pull_users(conn)
            join_all(conn, bot_client())
            run_dbt()
        except Exception:
            finish_run(conn, run_id, "failed", 0, 0)
            conn.commit()
            raise
        finish_run(conn, run_id, "ok", 0, 0)
        conn.commit()


if __name__ == "__main__":
    main()
