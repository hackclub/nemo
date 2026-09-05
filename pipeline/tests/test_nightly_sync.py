from jobs.nightly_sync import credential_faults, retryable
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


def test_preflight_treats_a_reply_with_no_credentials_as_a_fault():
    assert credential_faults({"detail": "invalid bearer token"}) == ["proxy: invalid bearer token"]
    assert credential_faults({}) == ["proxy: no credential report"]
