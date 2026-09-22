import threading

from bot.core import audit

BOT_ALLOWLIST = "bot_allowlist"

LIVE = """
SELECT g.channel_id, g.id, coalesce(array_agg(a.subject_id) FILTER
         (WHERE a.subject_id IS NOT NULL), '{}')
FROM fd.channel_guards g
LEFT JOIN fd.channel_guard_allows a ON a.guard_id = g.id
WHERE g.state = 'live' AND g.kind = %s
GROUP BY g.channel_id, g.id
"""

HELD = """
SELECT id, kind, channel_id, state, opened_by, case_id
FROM fd.channel_guards
WHERE channel_id = %s AND kind = %s AND state = 'live'
"""

OPEN = """
INSERT INTO fd.channel_guards (kind, channel_id, opened_by, case_id)
VALUES (%s, %s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING id
"""

LIFT = """
UPDATE fd.channel_guards
SET state = 'lifted', lifted_at = now(), lifted_by = %s, updated_at = now()
WHERE id = %s AND state = 'live'
RETURNING channel_id
"""

ALLOW = """
INSERT INTO fd.channel_guard_allows (guard_id, subject_id, label, added_by)
VALUES (%s, %s, %s, %s)
ON CONFLICT (guard_id, subject_id) DO UPDATE
SET label = coalesce(EXCLUDED.label, fd.channel_guard_allows.label)
RETURNING subject_id
"""

DISALLOW = """
DELETE FROM fd.channel_guard_allows WHERE guard_id = %s AND subject_id = %s
RETURNING subject_id
"""

ALLOWED = """
SELECT subject_id, label, added_by, added_at
FROM fd.channel_guard_allows WHERE guard_id = %s ORDER BY added_at
"""

TOLD_LATELY = """
SELECT told_ts FROM fd.channel_guard_events
WHERE guard_id = %s AND subject_id = %s AND told_until > now()
ORDER BY at DESC LIMIT 1
"""

HAPPENED = """
INSERT INTO fd.channel_guard_events
    (guard_id, channel_id, subject_id, bot_id, label, verb, said, message_ts, permalink,
     app_id, told_ts, told_until)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
RETURNING id
"""

_allowed = {}
_loaded = False
_lock = threading.Lock()


def refresh(conn, kind=BOT_ALLOWLIST):
    global _loaded
    found = {
        row[0]: (row[1], frozenset(row[2] or ()))
        for row in conn.execute(LIVE, (kind,)).fetchall()
    }
    with _lock:
        _allowed.clear()
        _allowed.update(found)
        _loaded = True
    return len(found)


def guarding(channel_id):
    with _lock:
        if not _loaded:
            return None
        return _allowed.get(channel_id)


def lets_past(channel_id, *ids):
    standing = guarding(channel_id)
    if standing is None:
        return True

    _, allowed = standing
    return any(one and one in allowed for one in ids)


def held(conn, channel_id, kind=BOT_ALLOWLIST):
    return conn.execute(HELD, (channel_id, kind)).fetchone()


def allowed(conn, guard_id):
    return conn.execute(ALLOWED, (guard_id,)).fetchall()


def open_guard(conn, channel_id, by, case_id=None, kind=BOT_ALLOWLIST):
    row = conn.execute(OPEN, (kind, channel_id, by, case_id)).fetchone()
    if row is None:
        return None

    guard_id = row[0]
    audit.record(
        conn, "channel_guard", guard_id, "opened", by,
        after={"kind": kind, "channel_id": channel_id},
    )
    return guard_id


def lift(conn, guard_id, by):
    row = conn.execute(LIFT, (by, guard_id)).fetchone()
    if row is None:
        return None

    audit.record(conn, "channel_guard", guard_id, "lifted", by,
                 before={"state": "live"}, after={"state": "lifted"})
    return row[0]


def allow(conn, guard_id, subject_id, by, label=None):
    row = conn.execute(ALLOW, (guard_id, subject_id, label, by)).fetchone()
    if row is None:
        return None

    audit.record(conn, "channel_allow", guard_id, "added", by,
                 after={"subject_id": subject_id, "label": label})
    return row[0]


def disallow(conn, guard_id, subject_id, by):
    row = conn.execute(DISALLOW, (guard_id, subject_id)).fetchone()
    if row is None:
        return None

    audit.record(conn, "channel_allow", guard_id, "removed", by,
                 before={"subject_id": subject_id}, after=None)
    return row[0]


def told_lately(conn, guard_id, subject_id):
    row = conn.execute(TOLD_LATELY, (guard_id, subject_id)).fetchone()
    return row[0] if row else None


KEPT_WORDS = 8000


def happened(conn, guard_id, channel_id, subject_id, verb, bot_id=None, label=None, said=None,
             message_ts=None, permalink=None, app_id=None, told_ts=None, told_until=None):
    return conn.execute(
        HAPPENED,
        (guard_id, channel_id, subject_id, bot_id, label, verb,
         (said or None) and said[:KEPT_WORDS],
         message_ts, permalink, app_id, told_ts, told_until),
    ).fetchone()[0]
