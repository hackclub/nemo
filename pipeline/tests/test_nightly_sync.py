from jobs.nightly_sync import retryable
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
