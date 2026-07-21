import os

from slack_sdk import WebClient
from slack_sdk.http_retry.builtin_handlers import ConnectionErrorRetryHandler, RateLimitErrorRetryHandler

RETRY_HANDLERS = [
    ConnectionErrorRetryHandler(max_retry_count=2),
    RateLimitErrorRetryHandler(max_retry_count=3),
]


def bot_client() -> WebClient:
    return WebClient(token=os.environ["SLACK_BOT_TOKEN"], retry_handlers=RETRY_HANDLERS)


def admin_client() -> WebClient:
    return WebClient(token=os.environ["SLACK_ADMIN_TOKEN"], retry_handlers=RETRY_HANDLERS)
