import logging
import os

from bot.core.db import session
from lib.proxy_client import ProxyClient, ProxyError

log = logging.getLogger("bot.privileged")

OFF = "off"
LOG = "log"
ON = "on"
MODES = (OFF, LOG, ON)

DEACTIVATE_SETTING = "nemo.deactivate"
SESSION_RESET_SETTING = "nemo.session_reset"
STRIKES_SETTING = "nemo.session_reset_strikes"
CAP_SETTING = "nemo.session_reset_max"

DEFAULT_STRIKES = 2
DEFAULT_CAP = 5

SETTING = "SELECT value FROM fd.app_settings WHERE key = %s"


def setting(key, conn=None):
    if conn is None:
        with session() as own:
            return setting(key, own)
    row = conn.execute(SETTING, (key,)).fetchone()
    return (row[0] if row and row[0] else "").strip()


def mode_of(key, conn=None):
    value = setting(key, conn).lower()
    return value if value in MODES else LOG


def number_of(key, fall_back, least, conn=None):
    try:
        return max(int(setting(key, conn)), least)
    except ValueError:
        return fall_back


def mode(conn=None):
    return mode_of(SESSION_RESET_SETTING, conn)


def deactivation_mode(conn=None):
    return mode_of(DEACTIVATE_SETTING, conn)


def strikes_needed(conn=None):
    return number_of(STRIKES_SETTING, DEFAULT_STRIKES, 1, conn)


def cap_per_guard(conn=None):
    return number_of(CAP_SETTING, DEFAULT_CAP, 0, conn)


def proxy():
    token = os.environ.get("PROXY_TOKEN_NEMO", "")
    if not token:
        raise ProxyError("PROXY_TOKEN_NEMO is not set")
    return ProxyClient(token=token, keep_alive=True)


CHANNEL_MISSING_ERRORS = ("channel_not_found", "not_in_channel")
ALREADY_DELETED = ("message_not_found", "already_deleted")

_admin_cache = {}


def channel_missing(failure):
    text = str(failure)
    return any(code in text for code in CHANNEL_MISSING_ERRORS)


def already_deleted(failure):
    text = str(failure)
    return any(code in text for code in ALREADY_DELETED)


def admin_user_id():
    if "id" not in _admin_cache:
        report = proxy().verify() or {}
        admin = (report.get("credentials") or {}).get("admin") or {}
        _admin_cache["id"] = admin.get("user_id")
        if not _admin_cache["id"]:
            log.warning("privileged: the proxy will not say who the admin account is")
    return _admin_cache["id"]


def delete_message(channel_id, ts, max_retries=2):
    proxy().call("chat.delete", {"channel": channel_id, "ts": ts},
                 credential="admin", max_retries=max_retries)


def history(channel_id, cursor=None, limit=200, oldest=None, latest=None):
    bounded = oldest is not None or latest is not None
    return proxy().call("conversations.history", {
        "channel": channel_id, "cursor": cursor, "limit": limit,
        "oldest": oldest, "latest": latest, "inclusive": 1 if bounded else None,
    }, credential="admin")


def replies(channel_id, ts, cursor=None, limit=200, oldest=None, latest=None):
    bounded = oldest is not None or latest is not None
    return proxy().call("conversations.replies", {
        "channel": channel_id, "ts": ts, "cursor": cursor, "limit": limit,
        "oldest": oldest, "latest": latest, "inclusive": 1 if bounded else None,
    }, credential="admin")


def search(query, page=1, count=100):
    return proxy().call("search.messages", {
        "query": query, "page": page, "count": count, "sort": "timestamp", "sort_dir": "desc",
        "team_id": os.environ.get("SLACK_TEAM_ID", "").strip() or None,
    }, credential="admin")


def kick(channel_id, user_id):
    try:
        proxy().call("conversations.kick", {"channel": channel_id, "user": user_id},
                     credential="admin", max_retries=0)
    except Exception as failure:
        if channel_missing(failure):
            log.info("privileged: cannot put %s out of %s, we are not in it", user_id, channel_id)
            return "away"
        log.warning("privileged: could not put %s out of %s: %s", user_id, channel_id, failure)
        return f"failed: {str(failure)[:200]}"

    log.info("privileged: put %s out of %s", user_id, channel_id)
    return "kicked"


def reset_sessions(user_id, conn=None):
    current_mode = mode(conn)
    if current_mode == OFF:
        return "off"
    if current_mode == LOG:
        log.warning("privileged: would reset every session for %s (%s is log)",
                    user_id, SESSION_RESET_SETTING)
        return "would"

    try:
        proxy().call("admin.users.session.reset", {"user_id": user_id},
                     credential="admin", max_retries=1)
    except Exception as failure:
        log.warning("privileged: could not reset sessions for %s: %s", user_id, failure)
        return f"failed: {str(failure)[:200]}"

    log.warning("privileged: reset every session for %s", user_id)
    return "reset"


DEACTIVATE = "scim.users.deactivate"
ACTIVATE = "scim.users.activate"
ASSIGN = "admin.users.assign"

DEACTIVATED = "deactivated"
REACTIVATED = "reactivated"


def set_account_state(user_id, method, done, doing, conn=None):
    current_mode = deactivation_mode(conn)
    if current_mode == OFF:
        return "off"
    if current_mode == LOG:
        log.warning("privileged: would %s %s (%s is log)", doing, user_id, DEACTIVATE_SETTING)
        return "would"

    try:
        proxy().call(method, {"user_id": user_id}, credential="admin", max_retries=1)
    except Exception as failure:
        log.warning("privileged: could not %s %s: %s", doing, user_id, failure)
        return f"failed: {str(failure)[:200]}"

    log.warning("privileged: %s %s", done, user_id)
    return done


PROFILE = "users.info"


def profile(user_id):
    if not user_id:
        return None

    try:
        response = proxy().call(PROFILE, {"user": user_id},
                             credential="admin", max_retries=1)
    except Exception as failure:  # noqa: BLE001
        log.warning("privileged: could not read the profile of %s: %s", user_id, failure)
        return None

    return (response or {}).get("user")


def deactivate(user_id, conn=None):
    return set_account_state(user_id, DEACTIVATE, DEACTIVATED, "deactivate", conn)


def assign_workspace(user_id):
    team_id = os.environ.get("SLACK_TEAM_ID", "").strip()
    if not team_id:
        return "failed: SLACK_TEAM_ID is not set"

    try:
        proxy().call(ASSIGN, {"team_id": team_id, "user_id": user_id},
                     credential="admin", max_retries=1)
    except Exception as failure:
        log.warning("privileged: could not assign %s to %s: %s", user_id, team_id, failure)
        return f"failed: {str(failure)[:200]}"

    log.warning("privileged: assigned %s to %s", user_id, team_id)
    return REACTIVATED


def reactivate(user_id, conn=None):
    outcome = set_account_state(user_id, ACTIVATE, REACTIVATED, "reactivate", conn)
    if outcome != REACTIVATED:
        return outcome
    return assign_workspace(user_id)
