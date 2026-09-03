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


def bot_client() -> WebClient:
    return WebClient(token=os.environ["SLACK_BOT_TOKEN"], retry_handlers=RETRY_HANDLERS)


def admin_client() -> WebClient:
    return WebClient(token=os.environ["SLACK_ADMIN_TOKEN"], retry_handlers=RETRY_HANDLERS)

