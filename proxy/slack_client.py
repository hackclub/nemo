import os

from slack_sdk import WebClient

UPSTREAM_TIMEOUT = 30

AUTH_ERRORS = {
    "invalid_auth",
    "not_authed",
    "token_revoked",
    "token_expired",
    "account_inactive",
    "no_permission",
    "missing_scope",
}


ADMIN_TOKEN_VARS = ("HUMAN_USER_TOKEN_XOXP", "SLACK_ADMIN_TOKEN")


def admin_token() -> str:
    for var in ADMIN_TOKEN_VARS:
        token = os.environ.get(var, "").strip()
        if token:
            return token
    return ""


def admin_client() -> WebClient:
    token = admin_token()
    if not token:
        raise RuntimeError(f"one of {' or '.join(ADMIN_TOKEN_VARS)} must be set")
    return WebClient(token=token, timeout=UPSTREAM_TIMEOUT, retry_handlers=[])
