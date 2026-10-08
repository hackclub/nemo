import logging
import os

from lib.proxy_client import ProxyClient, ProxyError

log = logging.getLogger("bot.privileged")

OFF = "off"
LOG = "log"
ON = "on"
MODES = (OFF, LOG, ON)

DEFAULT_STRIKES = 2
DEFAULT_CAP = 5


def mode():
    mode = (os.environ.get("FD_SESSION_RESET") or LOG).strip().lower()
    return mode if mode in MODES else LOG


def deactivation_mode():
    mode = (os.environ.get("FD_DEACTIVATE") or LOG).strip().lower()
    return mode if mode in MODES else LOG


def strikes_needed():
    try:
        return max(int(os.environ["FD_SESSION_RESET_STRIKES"]), 1)
    except (KeyError, ValueError):
        return DEFAULT_STRIKES


def cap_per_guard():
    try:
        return max(int(os.environ["FD_SESSION_RESET_MAX"]), 0)
    except (KeyError, ValueError):
        return DEFAULT_CAP


def proxy():
    token = os.environ.get("PROXY_TOKEN_NEMO", "")
    if not token:
        raise ProxyError("PROXY_TOKEN_NEMO must be set for the Fire Department to act in Slack")
    return ProxyClient(token=token, keep_alive=True)


NOT_THERE = ("channel_not_found", "not_in_channel")
ALREADY_GONE = ("message_not_found", "already_deleted")

_admin = {}


def absent(failure):
    text = str(failure)
    return any(one in text for one in NOT_THERE)


def gone(failure):
    text = str(failure)
    return any(one in text for one in ALREADY_GONE)


def admin_user_id():
    if "id" not in _admin:
        report = proxy().verify() or {}
        found = (report.get("credentials") or {}).get("admin") or {}
        _admin["id"] = found.get("user_id")
        if not _admin["id"]:
            log.warning("privileged: the proxy will not say who the admin account is")
    return _admin["id"]


def delete_message(channel_id, ts, max_retries=2):
    proxy().call("chat.delete", {"channel": channel_id, "ts": ts},
                 credential="admin", max_retries=max_retries)


def kick(channel_id, user_id):
    try:
        proxy().call("conversations.kick", {"channel": channel_id, "user": user_id},
                     credential="admin", max_retries=0)
    except Exception as failure:
        if absent(failure):
            log.info("privileged: cannot put %s out of %s, we are not in it", user_id, channel_id)
            return "away"
        log.warning("privileged: could not put %s out of %s: %s", user_id, channel_id, failure)
        return f"failed: {str(failure)[:200]}"

    log.info("privileged: put %s out of %s", user_id, channel_id)
    return "kicked"


def reset_sessions(user_id):
    how = mode()
    if how == OFF:
        return "off"
    if how == LOG:
        log.warning("privileged: would reset every session for %s (FD_SESSION_RESET=log)", user_id)
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

DEACTIVATED = "deactivated"
REACTIVATED = "reactivated"


def carried(user_id, method, done, doing):
    how = deactivation_mode()
    if how == OFF:
        return "off"
    if how == LOG:
        log.warning("privileged: would %s %s (FD_DEACTIVATE=log)", doing, user_id)
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
        found = proxy().call(PROFILE, {"user": user_id},
                             credential="admin", max_retries=1)
    except Exception as failure:  # noqa: BLE001
        log.warning("privileged: could not read the profile of %s: %s", user_id, failure)
        return None

    return (found or {}).get("user")


def deactivate(user_id):
    return carried(user_id, DEACTIVATE, DEACTIVATED, "deactivate")


def reactivate(user_id):
    return carried(user_id, ACTIVATE, REACTIVATED, "put back")
