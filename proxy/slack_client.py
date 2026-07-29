import os
from http.client import IncompleteRead, RemoteDisconnected
from urllib.error import URLError

from slack_sdk import WebClient
from slack_sdk.http_retry.builtin_handlers import ConnectionErrorRetryHandler, RateLimitErrorRetryHandler

RETRY_HANDLERS = [
    ConnectionErrorRetryHandler(
        max_retry_count=5,
        error_types=[URLError, ConnectionResetError, RemoteDisconnected, IncompleteRead],
    ),
    RateLimitErrorRetryHandler(max_retry_count=3),
]

AUTH_ERRORS = {
    "invalid_auth",
    "not_authed",
    "token_revoked",
    "token_expired",
    "account_inactive",
    "no_permission",
    "missing_scope",
}


def admin_client() -> WebClient:
    token = os.environ.get("SLACK_ADMIN_TOKEN", "")
    if not token:
        raise RuntimeError("SLACK_ADMIN_TOKEN must be set")
    return WebClient(token=token, retry_handlers=RETRY_HANDLERS)
