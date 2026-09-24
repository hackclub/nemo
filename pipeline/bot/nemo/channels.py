import logging
import os
import time

from bot.core import session

log = logging.getLogger("bot.nemo")

ON = "on"
GUARDED = "guarded"
OFF = "off"
MODES = (ON, GUARDED, OFF)

SETTING = "nemo.join_mode"
FALL_BACK = GUARDED

PAGE = 1000
DEFAULT_PACE = 1.2
DEFAULT_PER_SWEEP = 300

HOW = "SELECT value FROM fd.app_settings WHERE key = %s"

SET_HOW = """
INSERT INTO fd.app_settings (key, value, changed_by, changed_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, changed_by = EXCLUDED.changed_by, changed_at = now()
"""

GUARDED_CHANNELS = "SELECT DISTINCT channel_id FROM fd.channel_guards WHERE state = 'live'"

NOTED = """
INSERT INTO fd.channel_joins (channel_id, verb, why, by_user_id)
VALUES (%s, %s, %s, %s)
"""

SEATED = """
INSERT INTO fd.channel_membership (channel_id, inside, at)
VALUES (%s, %s, now())
ON CONFLICT (channel_id) DO UPDATE
SET inside = EXCLUDED.inside, at = now()
"""

WAS_INSIDE = "SELECT channel_id FROM fd.channel_membership WHERE inside"

INSIDE = "SELECT inside FROM fd.channel_membership WHERE channel_id = %s"


def pace():
    try:
        return max(float(os.environ["NEMO_JOIN_PACE_SECONDS"]), 0.0)
    except (KeyError, ValueError):
        return DEFAULT_PACE


def per_sweep():
    try:
        return max(int(os.environ["NEMO_JOIN_PER_SWEEP"]), 0)
    except (KeyError, ValueError):
        return DEFAULT_PER_SWEEP


def mode(conn):
    row = conn.execute(HOW, (SETTING,)).fetchone()
    said = (row[0] if row else "").strip().lower()
    return said if said in MODES else FALL_BACK


def set_mode(conn, how, by=None):
    said = (how or "").strip().lower()
    if said not in MODES:
        raise ValueError(f"{how!r} is not one of {', '.join(MODES)}")

    conn.execute(SET_HOW, (SETTING, said, by))
    return said


def guarded_channels(conn):
    return {row[0] for row in conn.execute(GUARDED_CHANNELS).fetchall()}


def team():
    return os.environ.get("SLACK_TEAM_ID", "").strip()


def _paged(call, **asked):
    where = team()
    if where:
        asked["team_id"] = where

    found = set()
    cursor = None
    while True:
        answer = call(limit=PAGE, cursor=cursor, **asked)
        for channel in answer.get("channels") or []:
            if channel.get("id") and not channel.get("is_archived"):
                found.add(channel["id"])
        cursor = (answer.get("response_metadata") or {}).get("next_cursor") or ""
        if not cursor:
            return found


def public_channels(client):
    return _paged(client.conversations_list, types="public_channel", exclude_archived=True)


def joined_channels(client):
    return _paged(client.users_conversations, types="public_channel", exclude_archived=True)


def wanted(client, conn, how=None):
    how = how or mode(conn)
    if how == OFF:
        return set()
    if how == GUARDED:
        return guarded_channels(conn)
    return public_channels(client)


def noted(conn, channel_id, verb, why=None, by=None):
    conn.execute(NOTED, (channel_id, verb, why, by))


def sat(conn, channel_id, inside):
    conn.execute(SEATED, (channel_id, inside))


def inside(conn, channel_id):
    row = conn.execute(INSIDE, (channel_id,)).fetchone()
    return bool(row and row[0])


def refusal(failure):
    answer = getattr(failure, "response", None)
    data = getattr(answer, "data", None) or {}
    return data.get("error") or type(failure).__name__


def join(client, conn, channel_id, by=None, verb="joined"):
    try:
        client.conversations_join(channel=channel_id)
    except Exception as failure:
        why = refusal(failure)
        noted(conn, channel_id, "refused", why, by)
        log.info("nemo: could not join %s: %s", channel_id, why)
        return False

    noted(conn, channel_id, verb, None, by)
    sat(conn, channel_id, True)
    return True


def seen(conn, seated):
    was = {row[0] for row in conn.execute(WAS_INSIDE).fetchall()}

    for channel_id in sorted(seated - was):
        conn.execute(SEATED, (channel_id, True))
    for channel_id in sorted(was - seated):
        conn.execute(SEATED, (channel_id, False))
        noted(conn, channel_id, "left", "gone at the sweep")

    return len(seated - was), len(was - seated)


def missing(client):
    with session() as conn:
        how = mode(conn)
        want = wanted(client, conn, how)

    seated = joined_channels(client)
    with session() as conn:
        took, lost = seen(conn, seated)
    if took or lost:
        log.info("nemo: sits in %s channel(s), %s new, %s gone", len(seated), took, lost)

    if how == OFF or not want:
        return how, []

    return how, sorted(want - seated)


def reconcile(client, cap=None):
    how, absent = missing(client)
    if not absent:
        return how, 0, 0

    cap = per_sweep() if cap is None else cap
    waiting = pace()
    joined = refused = 0

    for spot, channel_id in enumerate(absent[:cap] if cap else absent):
        if spot and waiting:
            time.sleep(waiting)
        with session() as conn:
            if join(client, conn, channel_id):
                joined += 1
            else:
                refused += 1

    log.info("nemo: %s mode, joined %s channel(s), %s refused, %s still to go",
             how, joined, refused, max(len(absent) - joined - refused, 0))
    return how, joined, refused
