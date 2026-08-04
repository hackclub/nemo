import os
import subprocess
from datetime import date, timedelta
from pathlib import Path

from dotenv import load_dotenv

from ingest.analytics_pull import pull_channel_day, pull_member_day, pull_users
from ingest.autojoin import join_all, name_unknown
from ingest.channel_range_pull import run as pull_channel_range
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


def stages(pull_date):
    return [
        ("team_stats", lambda conn: pull_team_stats(conn)),
        ("top_posters", lambda conn: pull_top_posters(conn)),
        (f"member_day {pull_date}", lambda conn: pull_member_day(conn, pull_date)),
        (f"channel_day {pull_date}", lambda conn: pull_channel_day(conn, pull_date)),
        ("member_range", lambda conn: pull_member_range(conn)),
        ("channel_range", lambda conn: pull_channel_range(conn)),
        ("admin_users_list", lambda conn: pull_users(conn)),
        ("users_list", lambda conn: pull_users_list(conn)),
        ("autojoin", lambda conn: join_all(conn, bot_client(), join=join_channels_enabled())),
        ("channel_names", lambda conn: name_unknown(conn, bot_client())),
        ("dbt", lambda conn: run_dbt()),
    ]


def run_stages(conn, plan):
    failed = []
    for index, (name, stage) in enumerate(plan, start=1):
        print(f"[{index}/{len(plan)}] {name}")
        try:
            stage(conn)
        except Exception as exc:
            conn.rollback()
            failed.append((name, f"{type(exc).__name__}: {exc}"))
            print(f"[{index}/{len(plan)}] {name}: FAILED {type(exc).__name__}: {exc}")
    return failed


def main():
    load_dotenv(ENV_FILE)
    pull_date = date.today() - timedelta(days=2)
    plan = stages(pull_date)
    with connect() as conn:
        for stale_id, stale_source in sweep_stale_runs(conn):
            print(f"abandoned stale run {stale_id} ({stale_source})")
        conn.commit()
        run_id = start_run(conn, SOURCE)
        conn.commit()

        failed = run_stages(conn, plan)

        if not failed:
            status = "ok"
        elif len(failed) == len(plan):
            status = "failed"
        else:
            status = "partial"
        finish_run(conn, run_id, status, 0, 0)
        conn.commit()

    print(f"{SOURCE}: {status}, {len(plan) - len(failed)}/{len(plan)} stages ok")
    for name, detail in failed:
        print(f"  failed: {name}: {detail}")
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
