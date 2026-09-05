import io
import json
import re
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
from ingest.channel_roster import name_unknown, record_channel_names
from ingest.channel_range_pull import run as pull_channel_range
from ingest.channel_history_pull import run as pull_channel_history
from ingest.channel_month_pull import run as pull_channel_month
from ingest.channel_replies_pull import run as pull_channel_replies
from ingest.dim_snapshot import run as snapshot_dimensions
from ingest.channel_range_pull import run_span as pull_channel_span
from ingest.first_reply import run as pull_first_reply
from ingest.member_channels import read_membership as pull_channel_membership
from ingest.member_channels import run as pull_member_channels
from ingest.prune import run as prune_rows
from ingest.member_range_pull import run as pull_member_range
from ingest.team_stats_pull import run as pull_team_stats
from ingest.top_posters_pull import run as pull_top_posters
from ingest.admin_users_pull import run as pull_admin_users
from ingest.users_list_pull import run as pull_users_list
from lib.db import (
    CHANNEL_DAY,
    MEMBER_DAY,
    SyncCancelled,
    analyze,
    connect,
    finish_run,
    ingest_run,
    raise_if_cancelled,
    refuse_if_seeded,
    run_step,
    set_worker,
    start_run,
)
from checks import headlines
from jobs import invariants
from lib import settings, sources
from lib.heartbeat import beating
from lib.paths import ENV_FILE, WAREHOUSE_DIR
from lib.proxy_client import InternalAuthError, ProxyClient, ProxyError, ProxyUnavailableError
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


RUN_RESULTS = DBT_DIR / "target" / "run_results.json"


def dbt(*args):
    proc = subprocess.Popen(
        ["dbt", *args, "--profiles-dir", str(DBT_DIR)],
        cwd=DBT_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    for line in proc.stdout:
        print(line, end="")
    return proc.wait()


def dbt_outcomes(results):
    failed, warned = [], []
    for result in results.get("results", []):
        name = result.get("unique_id", "?").split(".")[-1]
        status = result.get("status")
        if status in ("fail", "error"):
            failed.append((name, status))
        elif status == "warn":
            warned.append((name, status))
    return failed, warned


def run_dbt(conn=None):
    ensure_dbt_profile()

    def build(counts=None):
        if dbt("run") != 0:
            raise RuntimeError("dbt run exited non-zero, no mart was rebuilt")
        code = dbt("test")
        results = json.loads(RUN_RESULTS.read_text()) if RUN_RESULTS.exists() else {}
        failed, warned = dbt_outcomes(results)
        for name, status in warned:
            print(f"dbt test {status}: {name}")
        for name, status in failed:
            print(f"dbt test {status}: {name}")
        if failed:
            print(f"dbt: {len(failed)} test(s) failed, the marts were still rebuilt")
            if counts is not None:
                counts.status = "partial"
        elif code != 0:
            raise RuntimeError(f"dbt test exited {code} without recording a failure")

    if conn is None:
        build()
        return
    with ingest_run(conn, "dbt") as counts:
        build(counts)


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
        ("channel_roster", lambda conn: record_channel_names(conn, bot_client())),
        ("channel_names", lambda conn: name_unknown(conn, bot_client())),
        ("member_range", lambda conn: pull_member_range(conn)),
        ("channel_range", lambda conn: pull_channel_range(conn)),
        ("channel_span", lambda conn: pull_channel_span(conn)),
        ("channel_month", lambda conn: pull_channel_month(
            conn, recent=tuned(conn, "channel_month", "months"))),
        ("channel_history", lambda conn: pull_channel_history(
            conn, tuned(conn, "channel_history", "batch"))),
        ("users_list", lambda conn: pull_users_list(conn)),
        ("admin_users", lambda conn: pull_admin_users(conn)),
        ("dim_snapshot", lambda conn: snapshot_dimensions(conn)),
        ("channel_replies", lambda conn: pull_channel_replies(
            conn, tuned(conn, "channel_replies", "batch"))),
        ("member_channels", lambda conn: pull_member_channels(
            conn, tuned(conn, "member_channels", "batch"),
            tuned(conn, "member_channels", "cohort_days"))),
        ("channel_membership", lambda conn: pull_channel_membership(
            conn, bot_client(),
            tuned(conn, "channel_membership", "batch"),
            tuned(conn, "channel_membership", "cohort_days"))),
        ("first_reply", lambda conn: pull_first_reply(conn)),
        ("prune", lambda conn: prune_rows(conn)),
        ("dbt", lambda conn: run_dbt(conn)),
    ]


def tonight(conn, now=None):
    now = now or datetime.now(timezone.utc)
    return [
        (name, stage, settings.skip_reason(conn, name, now))
        for name, stage in stages()
    ]


GATEWAY_FAILURE = re.compile(r"proxy returned 50[234]\b")


def retryable(exc):
    if isinstance(exc, (SyncCancelled, InternalAuthError)):
        return False
    if isinstance(exc, ProxyUnavailableError):
        return True
    if isinstance(exc, ProxyError):
        return bool(GATEWAY_FAILURE.search(str(exc)))
    return True


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


def discard(conn):
    try:
        conn.rollback()
    except Exception as exc:
        return f"{type(exc).__name__}: {exc}"
    return None


def run_stage(conn, name, stage, run_id, index, total, budget=None, started=None):
    buffer = io.StringIO()
    for attempt in range(1, STAGE_ATTEMPTS + 1):
        try:
            with run_step(run_id, index, total), redirect_stdout(Tee(sys.stdout, buffer)):
                stage(conn)
        except SyncCancelled:
            torn = discard(conn)
            if torn:
                buffer.write(f"rollback failed, {torn}\n")
            record_step_output(run_id, index, name, buffer.getvalue())
            raise
        except Exception as exc:
            torn = discard(conn)
            detail = f"{type(exc).__name__}: {exc}"
            if torn:
                detail = f"{detail}, then rollback failed, {torn}"
            over = started is not None and over_budget(
                (time.monotonic() - started) / 60, budget, 1, name)
            if over:
                detail = f"{detail}, {over}, not retrying"
            buffer.write(f"{detail}\n")
            record_step_output(run_id, index, name, buffer.getvalue())
            if torn or over or attempt == STAGE_ATTEMPTS or not retryable(exc):
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
        detail = run_stage(conn, name, stage, run_id, index, len(plan), budget=budget, started=started)
        if detail:
            failed.append((name, detail))
            print(f"[{index}/{len(plan)}] {name}: FAILED {detail}")
    return failed, ran, skipped, cut


PREFLIGHT = "preflight"


def credential_faults(report):
    if "credentials" not in report:
        return [f"proxy: {report.get('detail') or 'no credential report'}"]
    faults = []
    for name, state in (report.get("credentials") or {}).items():
        if not state.get("ok"):
            faults.append(f"{name}: {state.get('error') or 'not ok'}")
    return faults


def preflight(run_id):
    try:
        report = ProxyClient().verify()
    except (ProxyError, ProxyUnavailableError) as exc:
        line = f"{PREFLIGHT}: could not reach the proxy, {type(exc).__name__}: {exc}"
        print(line)
        record_step_output(run_id, 0, PREFLIGHT, line + "\n")
        return [line]

    faults = credential_faults(report)
    if faults:
        line = f"{PREFLIGHT}: credential FAILED, " + "; ".join(faults)
    else:
        who = ", ".join(
            f"{name} ok ({state.get('user')})"
            for name, state in (report.get("credentials") or {}).items()
        )
        line = f"{PREFLIGHT}: {who}"
    print(line)
    record_step_output(run_id, 0, PREFLIGHT, line + "\n")
    return faults


def record_quality(conn, run_id):
    for name, job in (
        ("invariants", lambda: invariants.record(conn, run_id)),
        ("headlines", lambda: headlines.run(cross_only=True, record=True, run_id=run_id)),
    ):
        try:
            job()
        except Exception as exc:
            conn.rollback()
            print(f"{name}: not recorded, {type(exc).__name__}: {exc}")


def parent_status(cancelled, ran, skipped, cut, failed):
    if cancelled:
        return "cancelled"
    if ran == 0 and skipped == 0:
        return "failed"
    if ran and len(failed) == ran:
        return "failed"
    if cut or failed:
        return "partial"
    return "ok"


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
        preflight(run_id)

        cancelled = False
        ran = skipped = cut = 0
        budget = settings.budget_minutes(conn)
        try:
            failed, ran, skipped, cut = run_stages(conn, plan, run_id, budget)
        except SyncCancelled:
            conn.rollback()
            failed = []
            cancelled = True

        if not cancelled:
            record_quality(conn, run_id)
        status = parent_status(cancelled, ran, skipped, cut, failed)
        if status == "failed" and ran == 0 and skipped == 0 and not cancelled:
            failed = [("plan", "the plan was empty, so no stage ran and none was skipped")]
        finish_run(conn, run_id, status, 0, 0)
        conn.commit()

    print(f"{SOURCE}: {status}, {ran - len(failed)}/{ran} stages ok, "
          f"{skipped - cut} not due, {cut} cut for budget")
    for name, detail in failed:
        print(f"  failed: {name}: {detail}")
    return run_id, status


def main():
    load_dotenv(ENV_FILE)
    set_worker("manual")
    with beating("manual", "nightly_sync, run by hand"):
        _, status = run_sync()
    if status != "ok":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
