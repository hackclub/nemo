import io
import subprocess
import sys
import time
from contextlib import redirect_stdout
from datetime import datetime, timezone

from dotenv import load_dotenv

from ingest.analytics_pull import (
    backfill_days,
    pull_channel_day,
    pull_member_day,
)
from ingest.autojoin import name_unknown, record_channel_names
from ingest.channel_range_pull import run as pull_channel_range
from ingest.channel_range_pull import run_span as pull_channel_span
from ingest.first_reply import run as pull_first_reply
from ingest.member_channels import read_membership as pull_channel_membership
from ingest.member_channels import run as pull_member_channels
from ingest.member_history import run as pull_member_history
from ingest.prune import run as prune_rows
from ingest.member_range_pull import run as pull_member_range
from ingest.team_stats_pull import run as pull_team_stats
from ingest.top_posters_pull import run as pull_top_posters
from ingest.users_list_pull import run as pull_users_list
from lib.db import (
    CHANNEL_DAY,
    MEMBER_DAY,
    SyncCancelled,
    analyze,
    connect,
    finish_run,
    raise_if_cancelled,
    refuse_if_seeded,
    run_step,
    start_run,
)
from lib import settings, sources
from lib.paths import ENV_FILE, WAREHOUSE_DIR
from lib.proxy_client import InternalAuthError, ProxyError, ProxyUnavailableError
from lib.slack_client import bot_client

DBT_DIR = WAREHOUSE_DIR
SOURCE = "nightly_sync"
TRUTHY = {"1", "true", "yes", "on"}
STAGE_ATTEMPTS = 2
STEP_OUTPUT_LIMIT = 8000

STEP_OUTPUT_SQL = """
INSERT INTO raw.ingest_step_output (parent_run_id, step_index, source, output, created_at)
VALUES (%s, %s, %s, %s, now())
ON CONFLICT (parent_run_id, step_index) DO UPDATE SET
    source = EXCLUDED.source,
    output = EXCLUDED.output,
    created_at = now()
"""


def ensure_dbt_profile():
    profile = DBT_DIR / "profiles.yml"
    if profile.exists():
        return
    example = DBT_DIR / "profiles.yml.example"
    profile.write_text(example.read_text())
    print(f"dbt: wrote {profile.name} from {example.name}")


def run_dbt():
    ensure_dbt_profile()
    proc = subprocess.Popen(
        ["dbt", "build", "--profiles-dir", str(DBT_DIR)],
        cwd=DBT_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    for line in proc.stdout:
        print(line, end="")
    if proc.wait() != 0:
        raise RuntimeError(f"dbt build exited {proc.returncode}")


def tuned(conn, key, name):
    return settings.limit(conn, key, name)


def stages():
    return [
        ("team_stats", lambda conn: pull_team_stats(conn)),
        ("top_posters", lambda conn: pull_top_posters(conn)),
        ("member_days", lambda conn: backfill_days(
            conn, MEMBER_DAY, "member", pull_member_day, tuned(conn, "member_days", "batch"))),
        ("channel_days", lambda conn: backfill_days(
            conn, CHANNEL_DAY, "channel", pull_channel_day, tuned(conn, "channel_days", "batch"))),
        ("member_range", lambda conn: pull_member_range(conn)),
        ("channel_range", lambda conn: pull_channel_range(conn)),
        ("channel_span", lambda conn: pull_channel_span(conn)),
        ("users_list", lambda conn: pull_users_list(conn)),
        ("autojoin", lambda conn: record_channel_names(conn, bot_client())),
        ("channel_names", lambda conn: name_unknown(conn, bot_client())),
        ("member_history", lambda conn: pull_member_history(
            conn, tuned(conn, "member_history", "batch"))),
        ("member_channels", lambda conn: pull_member_channels(
            conn, tuned(conn, "member_channels", "batch"),
            tuned(conn, "member_channels", "cohort_days"))),
        ("channel_membership", lambda conn: pull_channel_membership(
            conn, bot_client(),
            tuned(conn, "channel_membership", "batch"),
            tuned(conn, "channel_membership", "cohort_days"))),
        ("first_reply", lambda conn: pull_first_reply(conn)),
        ("prune", lambda conn: prune_rows(conn)),
        ("dbt", lambda conn: run_dbt()),
    ]


def tonight(conn, now=None):
    now = now or datetime.now(timezone.utc)
    return [
        (name, stage, settings.skip_reason(conn, name, now))
        for name, stage in stages()
    ]


def retryable(exc):
    if isinstance(exc, (SyncCancelled, InternalAuthError)):
        return False
    if isinstance(exc, ProxyUnavailableError):
        return True
    return not isinstance(exc, ProxyError)


class Tee(io.TextIOBase):
    def __init__(self, *sinks):
        self.sinks = sinks

    def write(self, text):
        for sink in self.sinks:
            sink.write(text)
        return len(text)

    def flush(self):
        for sink in self.sinks:
            sink.flush()


def output_tail(text, limit=STEP_OUTPUT_LIMIT):
    if len(text) <= limit:
        return text
    return f"[truncated, showing the last {limit} of {len(text)} characters]\n" + text[-limit:]


def record_step_output(run_id, index, source, text):
    if run_id is None:
        return
    try:
        with connect() as out_conn, out_conn.cursor() as cur:
            cur.execute(STEP_OUTPUT_SQL, (run_id, index, source, output_tail(text)))
            out_conn.commit()
    except Exception:
        pass


def run_stage(conn, name, stage, run_id, index, total):
    buffer = io.StringIO()
    for attempt in range(1, STAGE_ATTEMPTS + 1):
        try:
            with run_step(run_id, index, total), redirect_stdout(Tee(sys.stdout, buffer)):
                stage(conn)
        except SyncCancelled:
            conn.rollback()
            record_step_output(run_id, index, name, buffer.getvalue())
            raise
        except Exception as exc:
            conn.rollback()
            detail = f"{type(exc).__name__}: {exc}"
            buffer.write(f"{detail}\n")
            record_step_output(run_id, index, name, buffer.getvalue())
            if attempt == STAGE_ATTEMPTS or not retryable(exc):
                return detail
            buffer.write(f"attempt {attempt + 1}\n")
            print(f"[{index}/{total}] {name}: {detail}, retrying")
        else:
            refresh_statistics(name)
            record_step_output(run_id, index, name, buffer.getvalue())
            return None
    return None


def refresh_statistics(name):
    tables = [
        table for table in sources.says(name, "writes")
        if table.startswith("raw.") and table.count(".") == 1
    ]
    if not tables:
        return

    refused = analyze(tables)
    if refused:
        print(f"{name}: statistics NOT refreshed, {refused}")


ALWAYS_RUNS = "dbt"


def over_budget(spent_minutes, budget_minutes, ran, name):
    if not budget_minutes or name == ALWAYS_RUNS:
        return None
    if ran < 1:
        return None
    if spent_minutes < budget_minutes:
        return None
    return f"over budget, {spent_minutes:.0f} of {budget_minutes} minutes spent"


SKIP_SQL = """
INSERT INTO raw.ingest_run
    (source, started_at, finished_at, status, parent_run_id, step_index, step_total)
VALUES (%s, clock_timestamp(), clock_timestamp(), 'skipped', %s, %s, %s)
"""


def record_skip(conn, run_id, index, total, name, why):
    with conn.cursor() as cur:
        cur.execute(SKIP_SQL, (name, run_id, index, total))
    conn.commit()
    record_step_output(run_id, index, name, f"{name}: skipped, {why}\n")


def run_stages(conn, plan, run_id, budget=None):
    started = time.monotonic()
    failed, ran, skipped, cut = [], 0, 0, 0
    for index, (name, stage, why) in enumerate(plan, start=1):
        raise_if_cancelled()
        if not why:
            spent = (time.monotonic() - started) / 60
            why = over_budget(spent, budget, ran, name)
            if why:
                cut += 1
        if why:
            skipped += 1
            print(f"[{index}/{len(plan)}] {name}: skipped, {why}")
            record_skip(conn, run_id, index, len(plan), name, why)
            continue
        ran += 1
        print(f"[{index}/{len(plan)}] {name}")
        detail = run_stage(conn, name, stage, run_id, index, len(plan))
        if detail:
            failed.append((name, detail))
            print(f"[{index}/{len(plan)}] {name}: FAILED {detail}")
    return failed, ran, skipped, cut


def stage_plan(name):
    plan = [(key, stage, None) for key, stage in stages() if key == name]
    if not plan:
        raise ValueError(f"unknown stage {name}")
    return plan


def run_sync(plan=None):
    with connect() as conn:
        refuse_if_seeded(conn)
        plan = plan or tonight(conn)
        run_id = start_run(conn, SOURCE)
        conn.commit()

        cancelled = False
        ran = skipped = cut = 0
        budget = settings.budget_minutes(conn)
        try:
            failed, ran, skipped, cut = run_stages(conn, plan, run_id, budget)
        except SyncCancelled:
            conn.rollback()
            failed = []
            cancelled = True

        if cancelled:
            status = "cancelled"
        elif ran == 0 and skipped == 0:
            status = "failed"
            failed = [("plan", "the plan was empty, so no stage ran and none was skipped")]
        elif cut:
            status = "partial"
        elif not failed:
            status = "ok"
        elif len(failed) == ran:
            status = "failed"
        else:
            status = "partial"
        finish_run(conn, run_id, status, 0, 0)
        conn.commit()

    print(f"{SOURCE}: {status}, {ran - len(failed)}/{ran} stages ok, "
          f"{skipped - cut} not due, {cut} cut for budget")
    for name, detail in failed:
        print(f"  failed: {name}: {detail}")
    return run_id, status


def main():
    load_dotenv(ENV_FILE)
    _, status = run_sync()
    if status != "ok":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
