import os
import subprocess
from datetime import date, timedelta
from pathlib import Path

from dotenv import load_dotenv

from ingest.analytics_pull import pull_channel_day, pull_member_day, pull_users
from ingest.autojoin import join_all, name_unknown
from ingest.channel_range_pull import run as pull_channel_range
from ingest.member_dates_reconciliation import run as reconcile_member_dates
from ingest.member_range_pull import run as pull_member_range
from ingest.team_stats_pull import run as pull_team_stats
from ingest.top_posters_pull import run as pull_top_posters
from ingest.users_list_pull import run as pull_users_list
from lib.db import connect, finish_run, start_run, sweep_stale_runs
from lib.slack_client import bot_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
DBT_DIR = Path(__file__).resolve().parents[2] / "dbt"
SOURCE = "nightly_sync"
TRUTHY = {"1", "true", "yes", "on"}


def join_channels_enabled():
    return os.environ.get("NIGHTLY_JOIN_CHANNELS", "").strip().lower() in TRUTHY


def run_dbt():
    subprocess.run(["dbt", "build", "--profiles-dir", str(DBT_DIR)], cwd=DBT_DIR, check=True)


def main():
    load_dotenv(ENV_FILE)
    pull_date = date.today() - timedelta(days=2)
    with connect() as conn:
        for stale_id, stale_source in sweep_stale_runs(conn):
            print(f"abandoned stale run {stale_id} ({stale_source})")
        conn.commit()
        run_id = start_run(conn, SOURCE)
        conn.commit()
        try:
            pull_team_stats(conn)
            pull_top_posters(conn)
            pull_member_day(conn, pull_date)
            pull_channel_day(conn, pull_date)
            pull_member_range(conn)
            pull_channel_range(conn)
            pull_users(conn)
            pull_users_list(conn)
            reconcile_member_dates(conn)
            join_all(conn, bot_client(), join=join_channels_enabled())
            name_unknown(conn, bot_client())
            run_dbt()
        except Exception:
            finish_run(conn, run_id, "failed", 0, 0)
            conn.commit()
            raise
        finish_run(conn, run_id, "ok", 0, 0)
        conn.commit()


if __name__ == "__main__":
    main()
