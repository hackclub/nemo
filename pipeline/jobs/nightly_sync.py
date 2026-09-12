import io
import json
import re
import subprocess
import sys
import time
from contextlib import redirect_stdout
from datetime import datetime, timezone

from dotenv import load_dotenv
from psycopg import sql

from ingest.analytics_pull import (
    backfill_days,
    pull_channel_day,
    pull_member_day,
)
from ingest.channel_roster import name_unknown, record_channel_names
from ingest.channel_range_pull import run as pull_channel_range
from ingest.channel_month_pull import run as pull_channel_month
from ingest.dim_snapshot import run as snapshot_dimensions
from ingest.channel_range_pull import run_span as pull_channel_span
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
    WORKER_BOOT,
    SyncCancelled,
    analyze,
    connect,
    finish_run,
    ingest_run,
    raise_if_cancelled,
    refuse_if_seeded,
    run_step,
    set_worker,
    sole_build,
    start_run,
    worker,
)
from checks import archive as archive_check
from checks import headlines
from checks import roles as roles_check
from checks import shards as shards_check
from jobs import invariants, reconcile
from lib import breaker
from lib import settings, sources
from lib.heartbeat import beating
from lib.paths import ENV_FILE, WAREHOUSE_DIR
from lib.proxy_client import InternalAuthError, ProxyClient, ProxyError, ProxyUnavailableError
from lib.slack_client import bot_client

DBT_DIR = WAREHOUSE_DIR
SOURCE = "nightly_sync"
TRANSFORM = "dbt"
TRUTHY = {"1", "true", "yes", "on"}
CLEAN_PARENT_OUTCOMES = frozenset({"ok", "partial"})
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
SOURCES_JSON = DBT_DIR / "target" / "sources.json"


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


TABLES_ONLY = ("--select", "+config.materialized:table")
OFF_THE_SPINE = TABLES_ONLY + ("--exclude", "fct_message+")

# A full nightly build runs entirely inside this candidate schema, invisible to readers,
# and is only swapped in for LIVE_SCHEMA (see promote_schema) once it passes its gate
# tests - so a failing or half-finished build never touches what dashboards are reading.
# The periodic partial refreshes in sync_worker.py deliberately skip all of this: they
# touch a subset of models and are meant to land directly, same as before.
LIVE_SCHEMA = "analytics"
CANDIDATE_SCHEMA = f"{LIVE_SCHEMA}_build"
PRIOR_SCHEMA = f"{LIVE_SCHEMA}_prior"
READ_ROLE = "rails_app"


def role_exists(conn, name):
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (name,))
        return cur.fetchone() is not None


def schema_exists(conn, name):
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_namespace WHERE nspname = %s", (name,))
        return cur.fetchone() is not None


def reset_candidate_schema(conn, name):
    with conn.cursor() as cur:
        cur.execute(sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(sql.Identifier(name)))
        cur.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(name)))
        # dbt (dbt_owner) creates and therefore owns every object it builds here, but
        # readers need USAGE on the schema itself before promotion; grant_read's
        # per-table post-hook only ever reaches the table, never the schema it lives in.
        if role_exists(conn, READ_ROLE):
            cur.execute(sql.SQL("GRANT USAGE ON SCHEMA {} TO {}")
                        .format(sql.Identifier(name), sql.Identifier(READ_ROLE)))
    conn.commit()


def promote_schema(conn, live, candidate, prior):
    with conn.cursor() as cur:
        cur.execute(sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(sql.Identifier(prior)))
        if schema_exists(conn, live):
            cur.execute(sql.SQL("ALTER SCHEMA {} RENAME TO {}")
                        .format(sql.Identifier(live), sql.Identifier(prior)))
        cur.execute(sql.SQL("ALTER SCHEMA {} RENAME TO {}")
                    .format(sql.Identifier(candidate), sql.Identifier(live)))
    conn.commit()


GATE_TESTS = (
    "assert_claimed_counts_track_slack",
    "assert_recurrence_funnel_never_widens",
    "assert_pending_invites_are_never_claimed",
    "assert_cohort_dates_are_not_stamped",
    "assert_member_dates_are_plausible",
    "assert_claim_rarely_precedes_creation",
    "assert_channel_membership_is_current",
    "assert_channel_membership_covers_the_window",
)


def check_freshness(counts=None):
    """Record how stale each declared source is. Stale is loud, never blocking:
    old data is a fact about the world, a failing test is a fact about the data."""
    code = dbt("source", "freshness")
    results = json.loads(SOURCES_JSON.read_text()) if SOURCES_JSON.exists() else {}
    stale = [
        r.get("unique_id", "?").split(".")[-1]
        for r in results.get("results", [])
        if r.get("status") in ("warn", "error", "runtime error")
    ]
    for name in stale:
        print(f"dbt source freshness: {name} is stale")
    if stale:
        print(f"dbt: {len(stale)} source(s) stale, the build continues on the data that is there")
        if counts is not None:
            counts.status = "partial"
    return code


def run_dbt(conn=None, select=(), wait_seconds=None):
    ensure_dbt_profile()
    full_build = conn is not None and not select

    def build(counts=None):
        check_freshness(counts)
        candidate_args = ()
        if full_build:
            reset_candidate_schema(conn, CANDIDATE_SCHEMA)
            candidate_args = ("--vars", json.dumps({"candidate_schema": CANDIDATE_SCHEMA}))
        if dbt("run", *candidate_args, *select) != 0:
            raise RuntimeError("dbt run exited non-zero, no mart was rebuilt")
        code = dbt("test", *candidate_args, *select)
        results = json.loads(RUN_RESULTS.read_text()) if RUN_RESULTS.exists() else {}
        failed, warned = dbt_outcomes(results)
        for name, status in warned:
            print(f"dbt test {status}: {name}")
        for name, status in failed:
            print(f"dbt test {status}: {name}")
        gated = [name for name, _ in failed if name in GATE_TESTS]
        if gated:
            kept = f" ({CANDIDATE_SCHEMA} kept for inspection, {LIVE_SCHEMA} still serves " \
                "the last validated build)" if full_build else ""
            raise RuntimeError(
                f"dbt: {len(gated)} gate test(s) failed, refusing to publish{kept}: "
                f"{', '.join(sorted(gated))}"
            )
        if failed:
            print(f"dbt: {len(failed)} test(s) failed, the marts were still rebuilt")
            if counts is not None:
                counts.status = "partial"
        elif code != 0:
            raise RuntimeError(f"dbt test exited {code} without recording a failure")
        if full_build:
            promote_schema(conn, LIVE_SCHEMA, CANDIDATE_SCHEMA, PRIOR_SCHEMA)
            print(f"dbt: promoted {CANDIDATE_SCHEMA} to {LIVE_SCHEMA}")

    with sole_build(wait_seconds=wait_seconds):
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
        ("users_list", lambda conn: pull_users_list(conn)),
        ("admin_users", lambda conn: pull_admin_users(conn)),
        ("dim_snapshot", lambda conn: snapshot_dimensions(conn)),
        ("member_channels", lambda conn: pull_member_channels(
            conn, tuned(conn, "member_channels", "batch"),
            tuned(conn, "member_channels", "cohort_days"))),
        ("channel_membership", lambda conn: pull_channel_membership(
            conn, bot_client(),
            tuned(conn, "channel_membership", "batch"),
            tuned(conn, "channel_membership", "cohort_days"))),
        ("prune", lambda conn: prune_rows(conn)),
        (TRANSFORM, lambda conn: run_dbt(conn)),
    ]


def tonight(conn, now=None):
    now = now or datetime.now(timezone.utc)
    return [
        (name, stage, settings.skip_reason(conn, name, now))
        for name, stage in stages()
    ]


GATEWAY_FAILURE = re.compile(r"proxy returned 50[234]\b")
LOCK_TIMEOUT = re.compile(r"canceling statement due to lock timeout")
ORPHAN_AFTER_SECONDS = 120

ORPHANED_DBT_SQL = """
SELECT pg_terminate_backend(pid)
FROM   pg_stat_activity
WHERE  usename = current_user
  AND  query LIKE '%%"app": "dbt"%%'
  AND  query_start < now() - make_interval(secs => %s)
  AND  backend_start < %s
  AND  pid <> pg_backend_pid()
"""


def reap_orphaned_dbt(before, after_seconds=ORPHAN_AFTER_SECONDS):
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute(ORPHANED_DBT_SQL, (after_seconds, before))
            killed = cur.rowcount
            conn.commit()
    except Exception as exc:
        print(f"nightly: could not reap orphaned dbt backends, {type(exc).__name__}: {exc}")
        return 0
    if killed > 0:
        print(f"nightly: terminated {killed} dbt backend(s) left by an earlier attempt")
    return killed


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
        began = datetime.now(timezone.utc)
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
            if LOCK_TIMEOUT.search(str(exc)):
                reap_orphaned_dbt(began)
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


def over_budget(spent_minutes, budget_minutes, ran, name):
    if not budget_minutes or name == TRANSFORM:
        return None
    if ran < 1:
        return None
    if spent_minutes < budget_minutes:
        return None
    return f"over budget, {spent_minutes:.0f} of {budget_minutes} minutes spent"


LANDED_SQL = """
SELECT coalesce(sum(rows_in), 0)
  FROM raw.ingest_run
 WHERE parent_run_id = %s
"""


def landed(conn, run_id):
    with conn.cursor() as cur:
        cur.execute(LANDED_SQL, (run_id,))
        return int(cur.fetchone()[0] or 0)


def due_anyway(conn, run_id, name, why):
    if name != TRANSFORM or not why:
        return why
    if not settings.enabled(conn, name):
        return why
    rows = landed(conn, run_id)
    if not rows:
        return why
    print(f"{name}: {why}, but {rows} rows landed tonight")
    return None


SKIP_SQL = """
INSERT INTO raw.ingest_run
    (source, source_key, logical_date, worker, worker_boot, started_at, finished_at, status,
     parent_run_id, step_index, step_total, error_detail)
VALUES (%s, %s, (clock_timestamp() AT TIME ZONE 'UTC')::date, %s, %s::uuid,
        clock_timestamp(), clock_timestamp(), 'skipped', %s, %s, %s, %s)
"""


def record_skip(conn, run_id, index, total, name, why):
    with conn.cursor() as cur:
        cur.execute(SKIP_SQL, (name, sources.key_for_run(name), worker(), WORKER_BOOT,
                               run_id, index, total, str(why)[:500]))
    conn.commit()
    record_step_output(run_id, index, name, f"{name}: skipped, {why}\n")


def run_stages(conn, plan, run_id, budget=None):
    started = time.monotonic()
    failed, ran, skipped, cut = [], 0, 0, 0
    for index, (name, stage, why) in enumerate(plan, start=1):
        raise_if_cancelled()
        why = due_anyway(conn, run_id, name, why)
        if not why:
            spent = (time.monotonic() - started) / 60
            why = over_budget(spent, budget, ran, name)
            if why:
                cut += 1
        if not why:
            why = breaker.blocked(conn, name)
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
        ("reconcile", lambda: reconcile.record(conn, run_id)),
        ("breaker", lambda: breaker.record(conn, run_id)),
        ("headlines", lambda: headlines.run(cross_only=True, record=True, run_id=run_id)),
        ("archive", lambda: archive_check.record(conn, run_id)),
        ("roles", lambda: roles_check.record(conn, run_id)),
        ("shards", lambda: shards_check.record(conn, run_id)),
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


def parent_fault(status, cancelled, failed):
    if status in CLEAN_PARENT_OUTCOMES:
        return None, None
    if cancelled:
        return "cancelled", "the run was cancelled before its stages finished"
    if not failed:
        return "local", f"the run ended {status} with no stage reporting a fault"
    named = ", ".join(name for name, _ in failed[:6])
    more = f" and {len(failed) - 6} more" if len(failed) > 6 else ""
    return "local", f"{len(failed)} stage(s) failed: {named}{more}"[:500]


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
        error_class, error_detail = parent_fault(status, cancelled, failed)
        finish_run(conn, run_id, status, 0, 0, error_class, error_detail)
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
