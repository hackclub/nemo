import pytest
import json

from jobs.nightly_sync import credential_faults, parent_status, retryable, dbt_outcomes
from lib.db import SyncCancelled
from lib.proxy_client import (
    InternalApiError,
    InternalAuthError,
    ProxyError,
    ProxyUnavailableError,
)


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
    assert "reap_orphaned_dbt()" in src


def test_the_reap_only_touches_this_user_s_own_stale_dbt_backends():
    from jobs import nightly_sync

    sql = nightly_sync.ORPHANED_DBT_SQL
    assert "usename = current_user" in sql
    assert 'query LIKE \'%"app": "dbt"%\'' in sql
    assert "pid <> pg_backend_pid()" in sql
    assert "query_start < now() - make_interval" in sql


def test_the_reap_survives_a_database_that_refuses_it():
    from unittest import mock

    from jobs import nightly_sync

    with mock.patch.object(nightly_sync, "connect", side_effect=RuntimeError("nope")):
        assert nightly_sync.reap_orphaned_dbt() == 0
