from slack_sdk.http_retry.builtin_handlers import RateLimitErrorRetryHandler

from lib.slack_client import admin_client, bot_client


def test_bot_client_uses_bot_token_and_retries_rate_limits(monkeypatch):
    monkeypatch.setenv("SLACK_BOT_TOKEN", "xoxb-test")
    client = bot_client()
    assert client.token == "xoxb-test"
    assert any(isinstance(h, RateLimitErrorRetryHandler) for h in client.retry_handlers)


def test_admin_client_uses_admin_token_and_retries_rate_limits(monkeypatch):
    monkeypatch.setenv("SLACK_ADMIN_TOKEN", "xoxp-test")
    client = admin_client()
    assert client.token == "xoxp-test"
    assert any(isinstance(h, RateLimitErrorRetryHandler) for h in client.retry_handlers)
