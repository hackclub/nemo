import logging
import threading

log = logging.getLogger("bot.nemo")

AUTORESPONSE_ON = "nemo.autoresponse_on"
AUTORESPONSE_EMOJI = "nemo.autoresponse_emoji"
AUTORESPONSE_CHANNEL = "nemo.autoresponse_channel"
AUTORESPONSE_BODY = "nemo.autoresponse_body"
AUTORESPONSE_COOLDOWN = "nemo.autoresponse_cooldown_days"
UNSUB_SHIELD_ON = "nemo.unsub_shield_on"
UNSUB_SHIELD_LINK = "nemo.unsub_shield_link"

KEYS = (
    AUTORESPONSE_ON, AUTORESPONSE_EMOJI, AUTORESPONSE_CHANNEL, AUTORESPONSE_BODY,
    AUTORESPONSE_COOLDOWN, UNSUB_SHIELD_ON, UNSUB_SHIELD_LINK,
)

COOLDOWN_FALL_BACK = 7
SLOWEST = 365

LIVE = "SELECT key, value FROM fd.app_settings WHERE key = ANY(%s)"

TICK = """
INSERT INTO fd.autoresponse_cooldown (user_id, sent_at)
VALUES (%s, now())
ON CONFLICT (user_id) DO UPDATE SET sent_at = now()
WHERE fd.autoresponse_cooldown.sent_at <= now() - make_interval(days => %s)
RETURNING sent_at
"""

_settings = {}
_loaded = False
_lock = threading.Lock()


def refresh(conn):
    global _loaded
    found = dict(conn.execute(LIVE, (list(KEYS),)).fetchall())
    with _lock:
        _settings.clear()
        _settings.update(found)
        _loaded = True
    return len(found)


def setting(key):
    with _lock:
        if not _loaded:
            return None
        return (_settings.get(key) or "").strip()


def on(key):
    return setting(key) == "on"


def setting_list(key):
    held = setting(key) or ""
    return [one.strip() for one in held.split(",") if one.strip()]


def cooldown_days():
    try:
        held = int(setting(AUTORESPONSE_COOLDOWN) or 0)
    except ValueError:
        held = 0
    return held if 1 <= held <= SLOWEST else COOLDOWN_FALL_BACK


def answering(channel_id, emoji):
    if not on(AUTORESPONSE_ON):
        return False
    if not setting(AUTORESPONSE_BODY):
        return False
    if channel_id != setting(AUTORESPONSE_CHANNEL):
        return False
    return emoji in setting_list(AUTORESPONSE_EMOJI)


def may_answer(conn, user_id):
    return conn.execute(TICK, (user_id, cooldown_days())).fetchone()


def shielding():
    return on(UNSUB_SHIELD_ON)
