import contextlib
import pytest
import json

from jobs.nightly_sync import credential_faults, parent_status, retryable, dbt_outcomes
from lib.db import RunCounts, SyncCancelled
from lib.proxy_client import (
    InternalApiError,
    InternalAuthError,
    ProxyError,
    ProxyUnavailableError,
)


class FakeSchemaCursor:
    def __init__(self, role_present=True, live_schema_present=True):
        self.log = []
        self.role_present = role_present
        self.live_schema_present = live_schema_present
        self._result = None

    def execute(self, query, params=None):
        text = query.as_string(None) if hasattr(query, "as_string") else query
        self.log.append(text)
        if "pg_roles" in text:
            self._result = (1,) if self.role_present else None
        elif "pg_namespace" in text:
            self._result = (1,) if self.live_schema_present else None
        else:
            self._result = None

    def fetchone(self):
        return self._result

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeSchemaConn:
    def __init__(self, role_present=True, live_schema_present=True):
        self.cur = FakeSchemaCursor(role_present, live_schema_present)
        self.commits = 0

    def cursor(self):
        return self.cur

    def commit(self):
        self.commits += 1

    @property
    def log(self):
        return self.cur.log


def test_a_dead_credential_is_not_retried():
    assert retryable(InternalAuthError("invalid_auth")) is False


def test_a_cancelled_run_is_not_retried():
    assert retryable(SyncCancelled("cancel requested")) is False


def test_a_rejected_request_is_not_retried():
    assert retryable(ProxyError("method not in the allowlist")) is False


def test_an_unreachable_proxy_is_retried_despite_subclassing_proxy_error():
    exc = ProxyUnavailableError("connection refused")
    assert isinstance(exc, ProxyError)
    assert retryable(exc) is True


def test_a_slack_side_failure_is_retried():
    assert retryable(InternalApiError("ratelimited")) is True


def test_an_ordinary_failure_is_retried():
    assert retryable(RuntimeError("boom")) is True
    assert retryable(KeyError("user_id")) is True


def test_a_gateway_failure_from_the_proxy_is_retried():
    assert retryable(ProxyError("proxy returned 502: ")) is True
    assert retryable(ProxyError("proxy returned 503: ")) is True
    assert retryable(ProxyError("proxy returned 504: ")) is True


def test_a_refused_request_from_the_proxy_is_still_not_retried():
    assert retryable(ProxyError("proxy returned 401: invalid bearer token")) is False
    assert retryable(ProxyError("proxy returned 403: method not allowed")) is False
    assert retryable(ProxyError("proxy returned 400: unknown credential")) is False
    assert retryable(ProxyError("proxy returned 500: ")) is False


def test_a_walk_integrity_failure_is_not_retried():
    assert retryable(ProxyError("search.messages: page repeated after 1500 records")) is False


def test_preflight_names_the_dead_credential():
    report = {"ok": False, "credentials": {
        "internal": {"ok": False, "error": "invalid_auth"},
        "admin": {"ok": True, "user": "epsmnemosyne"},
    }}
    assert credential_faults(report) == ["internal: invalid_auth"]


def test_preflight_is_quiet_when_both_credentials_hold():
    report = {"ok": True, "credentials": {
        "internal": {"ok": True, "user": "dracula"},
        "admin": {"ok": True, "user": "epsmnemosyne"},
    }}
    assert credential_faults(report) == []


def test_preflight_reports_a_missing_credential_without_an_error_string():
    assert credential_faults({"credentials": {"admin": {"ok": False}}}) == ["admin: not ok"]


def test_parent_status_cases():
    ok = []
    fails = [("a", "x")]
    assert parent_status(True, 5, 0, 0, ok) == "cancelled"
    assert parent_status(False, 0, 0, 0, ok) == "failed"
    assert parent_status(False, 0, 20, 0, ok) == "ok"
    assert parent_status(False, 20, 0, 0, ok) == "ok"
    assert parent_status(False, 20, 0, 0, fails) == "partial"
    assert parent_status(False, 1, 0, 0, fails) == "failed"
    assert parent_status(False, 20, 0, 3, ok) == "partial"
    assert parent_status(False, 19, 0, 1, fails * 19) == "failed"
    assert parent_status(False, 20, 5, 1, fails) == "partial"
    assert parent_status(True, 0, 0, 0, ok) == "cancelled"


def test_dbt_outcomes_split_fail_and_error_from_warn():
    results = {"results": [
        {"unique_id": "test.mnemosyne.not_null_dim_member_user_id", "status": "pass"},
        {"unique_id": "test.mnemosyne.assert_cohort_dates_are_not_stamped", "status": "warn"},
        {"unique_id": "test.mnemosyne.unique_mart_growth_month", "status": "fail"},
        {"unique_id": "test.mnemosyne.assert_member_dates_are_plausible", "status": "error"},
        {"unique_id": "model.mnemosyne.mart_growth", "status": "success"},
    ]}
    failed, warned = dbt_outcomes(results)
    assert failed == [("unique_mart_growth_month", "fail"), ("assert_member_dates_are_plausible", "error")]
    assert warned == [("assert_cohort_dates_are_not_stamped", "warn")]
    assert dbt_outcomes({}) == ([], [])


def test_preflight_treats_a_reply_with_no_credentials_as_a_fault():
    assert credential_faults({"detail": "invalid bearer token"}) == ["proxy: invalid bearer token"]
    assert credential_faults({}) == ["proxy: no credential report"]


def test_a_gate_test_failure_refuses_to_publish(monkeypatch, tmp_path):
    from jobs import nightly_sync

    results = tmp_path / "run_results.json"
    results.write_text(json.dumps({"results": [
        {"unique_id": "test.mnemosyne.assert_claimed_counts_track_slack", "status": "fail"},
    ]}))
    monkeypatch.setattr(nightly_sync, "RUN_RESULTS", results)
    monkeypatch.setattr(nightly_sync, "ensure_dbt_profile", lambda: None)
    monkeypatch.setattr(nightly_sync, "check_freshness", lambda counts=None: 0)
    monkeypatch.setattr(nightly_sync, "dbt", lambda *a: 0)
    monkeypatch.setattr(nightly_sync, "sole_build",
                        lambda **kw: contextlib.nullcontext())

    with pytest.raises(RuntimeError, match="refusing to publish"):
        nightly_sync.run_dbt()


def test_an_ungated_test_failure_still_publishes_and_marks_the_run_partial(monkeypatch, tmp_path):
    from jobs import nightly_sync

    results = tmp_path / "run_results.json"
    results.write_text(json.dumps({"results": [
        {"unique_id": "test.mnemosyne.not_null_fct_message_ts", "status": "fail"},
    ]}))
    monkeypatch.setattr(nightly_sync, "RUN_RESULTS", results)
    monkeypatch.setattr(nightly_sync, "ensure_dbt_profile", lambda: None)
    monkeypatch.setattr(nightly_sync, "check_freshness", lambda counts=None: 0)
    monkeypatch.setattr(nightly_sync, "dbt", lambda *a: 0)
    monkeypatch.setattr(nightly_sync, "sole_build",
                        lambda **kw: contextlib.nullcontext())

    nightly_sync.run_dbt()


def test_every_gate_test_names_a_singular_test_that_exists():
    from pathlib import Path

    from jobs.nightly_sync import GATE_TESTS
    from lib.paths import WAREHOUSE_DIR

    on_disk = {p.stem for p in Path(WAREHOUSE_DIR, "tests").glob("*.sql")}
    assert set(GATE_TESTS) <= on_disk, set(GATE_TESTS) - on_disk


def test_a_clean_parent_records_no_fault():
    from jobs.nightly_sync import parent_fault

    assert parent_fault("ok", False, []) == (None, None)
    assert parent_fault("partial", False, [("dbt", "x")]) == (None, None)


def test_every_terminal_parent_outcome_is_classified():
    from jobs.nightly_sync import parent_fault, parent_status

    for cancelled, ran, skipped, cut, failed in [
        (True, 0, 0, 0, []),
        (False, 0, 0, 0, []),
        (False, 2, 0, 0, [("a", "x"), ("b", "y")]),
    ]:
        status = parent_status(cancelled, ran, skipped, cut, failed)
        klass, detail = parent_fault(status, cancelled, failed)
        assert klass is not None, status
        assert detail


def test_every_check_module_is_wired_into_the_nightly():
    import inspect
    from pathlib import Path

    from jobs import nightly_sync

    modules = {p.stem for p in (Path(__file__).parent.parent / "checks").glob("*.py")
               if p.stem != "__init__"}
    src = inspect.getsource(nightly_sync.record_quality)
    missing = [m for m in sorted(modules) if f'("{m}"' not in src]
    assert missing == [], f"check modules written but never run: {missing}"


def test_a_failing_check_cannot_break_the_nightly():
    import inspect

    from jobs import nightly_sync

    src = inspect.getsource(nightly_sync.record_quality)
    assert "except Exception" in src
    assert "conn.rollback()" in src


def test_a_lock_timeout_reaps_the_previous_attempt_before_retrying():
    import inspect

    from jobs import nightly_sync

    src = inspect.getsource(nightly_sync.run_stage)
    assert "LOCK_TIMEOUT.search" in src
    assert "reap_orphaned_dbt(began)" in src


def test_the_reap_only_touches_this_user_s_own_stale_dbt_backends():
    from jobs import nightly_sync

    sql = nightly_sync.ORPHANED_DBT_SQL
    assert "usename = current_user" in sql
    assert 'query LIKE \'%%"app": "dbt"%%\'' in sql, (
        "psycopg reads a single %% as a placeholder, so the LIKE pattern has to double them "
        "or every reap dies with ProgrammingError before it terminates anything"
    )
    assert "pid <> pg_backend_pid()" in sql
    assert "query_start < now() - make_interval" in sql


def test_the_reap_survives_a_database_that_refuses_it():
    from datetime import datetime, timezone
    from unittest import mock

    from jobs import nightly_sync

    with mock.patch.object(nightly_sync, "connect", side_effect=RuntimeError("nope")):
        assert nightly_sync.reap_orphaned_dbt(datetime.now(timezone.utc)) == 0


def test_the_periodic_refresh_is_closed_under_its_dependencies():
    from jobs import nightly_sync

    assert nightly_sync.TABLES_ONLY == ("--select", "+config.materialized:table"), (
        "config.materialized:table selects the tables but not the views they read, so a view "
        "the last run failed to build stays missing until a full nightly; the + pulls the "
        "ancestors in and lets the refresh rebuild them"
    )


def test_reset_candidate_schema_drops_creates_and_grants_usage():
    from jobs import nightly_sync

    conn = FakeSchemaConn(role_present=True)
    nightly_sync.reset_candidate_schema(conn, "analytics_build")

    assert conn.log == [
        'DROP SCHEMA IF EXISTS "analytics_build" CASCADE',
        'CREATE SCHEMA "analytics_build"',
        "SELECT 1 FROM pg_roles WHERE rolname = %s",
        'GRANT USAGE ON SCHEMA "analytics_build" TO "rails_app"',
    ]
    assert conn.commits == 1


def test_reset_candidate_schema_skips_the_grant_when_the_role_is_absent():
    from jobs import nightly_sync

    conn = FakeSchemaConn(role_present=False)
    nightly_sync.reset_candidate_schema(conn, "analytics_build")

    assert "GRANT" not in " ".join(conn.log)


def test_promote_schema_swaps_live_and_candidate_and_drops_the_old_prior():
    from jobs import nightly_sync

    conn = FakeSchemaConn(live_schema_present=True)
    nightly_sync.promote_schema(conn, "analytics", "analytics_build", "analytics_prior")

    assert conn.log == [
        'DROP SCHEMA IF EXISTS "analytics_prior" CASCADE',
        "SELECT 1 FROM pg_namespace WHERE nspname = %s",
        'ALTER SCHEMA "analytics" RENAME TO "analytics_prior"',
        'ALTER SCHEMA "analytics_build" RENAME TO "analytics"',
    ]
    assert conn.commits == 1


def test_promote_schema_skips_the_rename_away_when_live_does_not_exist_yet():
    # first-ever build on a fresh database: there is no live schema to preserve
    from jobs import nightly_sync

    conn = FakeSchemaConn(live_schema_present=False)
    nightly_sync.promote_schema(conn, "analytics", "analytics_build", "analytics_prior")

    assert 'ALTER SCHEMA "analytics" RENAME TO "analytics_prior"' not in conn.log
    assert 'ALTER SCHEMA "analytics_build" RENAME TO "analytics"' in conn.log


def test_a_full_build_builds_the_candidate_schema_and_promotes_on_success(monkeypatch, tmp_path):
    from jobs import nightly_sync

    results = tmp_path / "run_results.json"
    results.write_text(json.dumps({"results": []}))
    monkeypatch.setattr(nightly_sync, "RUN_RESULTS", results)
    monkeypatch.setattr(nightly_sync, "ensure_dbt_profile", lambda: None)
    monkeypatch.setattr(nightly_sync, "check_freshness", lambda counts=None: 0)
    monkeypatch.setattr(nightly_sync, "sole_build", lambda **kw: contextlib.nullcontext())
    monkeypatch.setattr(nightly_sync, "ingest_run",
                        lambda conn, source: contextlib.nullcontext(RunCounts()))

    dbt_calls = []
    monkeypatch.setattr(nightly_sync, "dbt", lambda *a: dbt_calls.append(a) or 0)
    reset_calls = []
    monkeypatch.setattr(nightly_sync, "reset_candidate_schema",
                        lambda conn, name: reset_calls.append(name))
    promote_calls = []
    monkeypatch.setattr(nightly_sync, "promote_schema",
                        lambda conn, live, candidate, prior: promote_calls.append((live, candidate, prior)))

    nightly_sync.run_dbt(conn=object(), select=())

    assert reset_calls == [nightly_sync.CANDIDATE_SCHEMA]
    assert promote_calls == [
        (nightly_sync.LIVE_SCHEMA, nightly_sync.CANDIDATE_SCHEMA, nightly_sync.PRIOR_SCHEMA)
    ]
    assert len(dbt_calls) == 2, "dbt run then dbt test"
    for call in dbt_calls:
        assert "--vars" in call
        assert json.dumps({"candidate_schema": nightly_sync.CANDIDATE_SCHEMA}) in call


def test_a_full_build_does_not_promote_when_a_gate_test_fails(monkeypatch, tmp_path):
    from jobs import nightly_sync

    results = tmp_path / "run_results.json"
    results.write_text(json.dumps({"results": [
        {"unique_id": "test.mnemosyne.assert_claimed_counts_track_slack", "status": "fail"},
    ]}))
    monkeypatch.setattr(nightly_sync, "RUN_RESULTS", results)
    monkeypatch.setattr(nightly_sync, "ensure_dbt_profile", lambda: None)
    monkeypatch.setattr(nightly_sync, "check_freshness", lambda counts=None: 0)
    monkeypatch.setattr(nightly_sync, "dbt", lambda *a: 0)
    monkeypatch.setattr(nightly_sync, "sole_build", lambda **kw: contextlib.nullcontext())
    monkeypatch.setattr(nightly_sync, "ingest_run",
                        lambda conn, source: contextlib.nullcontext(RunCounts()))
    monkeypatch.setattr(nightly_sync, "reset_candidate_schema", lambda conn, name: None)
    promote_calls = []
    monkeypatch.setattr(nightly_sync, "promote_schema",
                        lambda conn, live, candidate, prior: promote_calls.append(1))

    with pytest.raises(RuntimeError, match="refusing to publish"):
        nightly_sync.run_dbt(conn=object(), select=())

    assert promote_calls == [], "a gated failure must never promote the candidate"


def test_a_partial_select_never_touches_the_candidate_schema(monkeypatch, tmp_path):
    # the periodic mart refresh in sync_worker.py always passes a non-empty select and
    # must keep landing directly - it only ever rebuilds a subset of models
    from jobs import nightly_sync

    results = tmp_path / "run_results.json"
    results.write_text(json.dumps({"results": []}))
    monkeypatch.setattr(nightly_sync, "RUN_RESULTS", results)
    monkeypatch.setattr(nightly_sync, "ensure_dbt_profile", lambda: None)
    monkeypatch.setattr(nightly_sync, "check_freshness", lambda counts=None: 0)
    monkeypatch.setattr(nightly_sync, "sole_build", lambda **kw: contextlib.nullcontext())
    monkeypatch.setattr(nightly_sync, "ingest_run",
                        lambda conn, source: contextlib.nullcontext(RunCounts()))

    dbt_calls = []
    monkeypatch.setattr(nightly_sync, "dbt", lambda *a: dbt_calls.append(a) or 0)
    monkeypatch.setattr(nightly_sync, "reset_candidate_schema",
                        lambda conn, name: (_ for _ in ()).throw(AssertionError("not for a partial select")))
    monkeypatch.setattr(nightly_sync, "promote_schema",
                        lambda *a: (_ for _ in ()).throw(AssertionError("not for a partial select")))

    nightly_sync.run_dbt(conn=object(), select=nightly_sync.TABLES_ONLY)

    for call in dbt_calls:
        assert "--vars" not in call
    assert dbt_calls[0] == ("run", *nightly_sync.TABLES_ONLY)


def test_every_dbt_build_takes_the_single_build_lock():
    import inspect

    from jobs import nightly_sync

    src = inspect.getsource(nightly_sync.run_dbt)
    assert "with sole_build(wait_seconds=wait_seconds):" in src, (
        "the nightly, the fifteen-minute refresh and the transform CLI all reach dbt through "
        "run_dbt, so the lock belongs here or a hand-run build still races the scheduler"
    )


def test_the_reap_cannot_kill_a_backend_this_attempt_started():
    from jobs import nightly_sync

    sql = nightly_sync.ORPHANED_DBT_SQL
    assert "backend_start < %s" in sql, (
        "without a floor the reaper kills any dbt backend older than two minutes, including "
        "the long build it was called to protect"
    )


def test_the_reap_demands_a_floor_rather_than_defaulting_to_none():
    import inspect

    from jobs import nightly_sync

    floor = inspect.signature(nightly_sync.reap_orphaned_dbt).parameters["before"]
    assert floor.default is inspect.Parameter.empty


def test_a_refused_build_is_a_skip_for_the_refresh_not_a_failure():
    import inspect

    from jobs import sync_worker

    src = inspect.getsource(sync_worker.refresh_marts)
    assert "except AlreadyRunning" in src
    assert src.index("except AlreadyRunning") < src.index("except Exception")


def test_the_cheap_tier_leaves_the_spine_and_everything_under_it_alone():
    from jobs import nightly_sync

    assert nightly_sync.OFF_THE_SPINE == (
        "--select", "+config.materialized:table", "--exclude", "fct_message+"
    ), "24 models refresh without touching the 22 that queue behind a 54M-row scan"


def test_the_spine_tier_runs_on_its_own_slower_clock():
    import inspect

    from jobs import sync_worker

    src = inspect.getsource(sync_worker.refresh_marts)
    assert "spine_every()" in src and "transform_every()" in src
    assert "OFF_THE_SPINE" in src and "TABLES_ONLY" in src
    assert sync_worker.DEFAULT_SPINE_SECONDS > sync_worker.DEFAULT_TRANSFORM_SECONDS


def test_the_first_pass_builds_on_a_freshly_booted_node():
    from unittest import mock

    from jobs import sync_worker

    calls = []
    with mock.patch.object(sync_worker.time, "monotonic", return_value=3.0), \
         mock.patch.object(sync_worker, "run_dbt", lambda *a, **kw: calls.append(kw["select"])), \
         mock.patch.object(sync_worker, "connect", mock.MagicMock()), \
         mock.patch.object(sync_worker, "transform_every", return_value=900), \
         mock.patch.object(sync_worker, "spine_every", return_value=3600):
        sync_worker.refresh_marts(sync_worker.NEVER, {"note": "idle"}, sync_worker.NEVER)

    assert calls == [sync_worker.TABLES_ONLY], (
        "monotonic() counts from boot, so a 0.0 baseline reads as 'ran at boot' and holds the "
        "first build back until the node's uptime passes the interval"
    )


def test_the_two_tiers_keep_separate_clocks():
    from unittest import mock

    from jobs import sync_worker

    calls = []
    with mock.patch.object(sync_worker, "run_dbt", lambda *a, **kw: calls.append(kw["select"])), \
         mock.patch.object(sync_worker, "connect", mock.MagicMock()), \
         mock.patch.object(sync_worker, "transform_every", return_value=1), \
         mock.patch.object(sync_worker, "spine_every", return_value=10_000):
        state = {"note": "idle"}
        refreshed, spined = sync_worker.refresh_marts(sync_worker.NEVER, state, sync_worker.NEVER)
        assert calls == [sync_worker.TABLES_ONLY], "the first pass has to build the spine once"
        refreshed, spined = sync_worker.refresh_marts(sync_worker.NEVER, state, spined)
        assert calls[-1] == sync_worker.OFF_THE_SPINE, "the spine is not due again yet"
        assert state["note"] == "idle", "the worker's note has to come back"
