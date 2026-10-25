import datetime as dt
import threading

from bot.core import audit
from bot.nemo.views import action

SHUSH = "shush"
CHANNEL_BAN = "channel_ban"
DEACTIVATION = "deactivation"

FIREHOSE = "firehose"

SLACK_LIFT_KINDS = (DEACTIVATION,)

NO_GUARD = action.NO_GUARD
NO_CASE = action.NO_CASE
OTHER_CASE = action.OTHER_CASE
THIS_CASE = action.THIS_CASE

FIELDS = (
    "id", "kind", "subject_id", "channel_id", "state", "enforcement_status", "enforced_by",
    "case_id", "opened_by", "opened_at", "reason", "expires_at",
)

COLUMNS = ", ".join(FIELDS)

ACTIVE_GUARD = f"""
SELECT {COLUMNS} FROM fd.member_guards
WHERE subject_id = %s AND kind = %s
  AND coalesce(channel_id, '') = coalesce(%s, '')
  AND state IN ('live', 'lifting')
"""

FOR_MEMBER = f"""
SELECT {COLUMNS} FROM fd.member_guards
WHERE subject_id = %s AND state IN ('live', 'lifting')
ORDER BY opened_at, id
"""

ON_CASE = f"""
SELECT {COLUMNS} FROM fd.member_guards
WHERE case_id = %s AND state IN ('live', 'lifting')
ORDER BY opened_at, id
"""


def row_to_guard(row):
    return dict(zip(FIELDS, row)) if row else None


def enforceable(type_key):
    return action.guard_kind(type_key) is not None


def active_guard(conn, subject_id, kind, channel_id=None):
    return row_to_guard(conn.execute(ACTIVE_GUARD, (subject_id, kind, channel_id)).fetchone())


def for_member(conn, subject_id):
    return [row_to_guard(row) for row in conn.execute(FOR_MEMBER, (subject_id,)).fetchall()]


def on_case(conn, case_id):
    return [row_to_guard(row) for row in conn.execute(ON_CASE, (case_id,)).fetchall()]


def for_action(conn, type_key, subject_id, channel_id=None):
    kind = action.guard_kind(type_key)
    if kind is None:
        return None
    if action.guard_scope(type_key) != "channel":
        channel_id = None
    return active_guard(conn, subject_id, kind, channel_id)


def guard_status(conn, type_key, subject_id, case_id=None, channel_id=None):
    if not enforceable(type_key):
        return {"enforceable": False, "guard": None, "relation": NO_GUARD, "case_id": case_id}
    if not subject_id:
        return {"enforceable": True, "guard": None, "relation": NO_GUARD, "case_id": case_id}

    existing_guard = for_action(conn, type_key, subject_id, channel_id)
    return {
        "enforceable": True,
        "guard": existing_guard,
        "relation": guard_relation(existing_guard, case_id),
        "case_id": case_id,
    }


def guard_relation(guard, case_id=None):
    if guard is None:
        return NO_GUARD
    if guard["case_id"] is None:
        return NO_CASE
    if case_id is not None and guard["case_id"] == case_id:
        return THIS_CASE
    return OTHER_CASE


OPEN = """
INSERT INTO fd.member_guards
    (kind, subject_id, channel_id, case_id, opened_by, reason, expires_at,
     enforced_by, enforcement_status)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING id
"""

ATTACH = """
UPDATE fd.member_guards SET case_id = %s, updated_at = now()
WHERE id = %s AND case_id IS NULL AND state IN ('live', 'lifting')
RETURNING id
"""

SET_EXPIRY = """
UPDATE fd.member_guards SET expires_at = %s, updated_at = now()
WHERE id = %s AND state IN ('live', 'lifting') AND enforced_by <> 'firehose'
RETURNING id
"""

LINK = """
UPDATE fd.actions SET guard_id = %s WHERE id = %s AND guard_id IS NULL RETURNING id
"""


def open_guard(conn, kind, subject_id, by, reason, channel_id=None, case_id=None,
               expires_at=None, by_hand=False):
    enforced_by, enforcement_status = ("by_hand", "held") if by_hand else ("nemo", "pending")
    row = conn.execute(
        OPEN,
        (kind, subject_id, channel_id, case_id, by, reason, expires_at, enforced_by,
         enforcement_status),
    ).fetchone()
    if row is None:
        return None

    audit.record(
        conn, "member_guard", row[0], "opened", by,
        after={"kind": kind, "subject_id": subject_id, "channel_id": channel_id,
               "case_id": case_id, "enforced_by": enforced_by,
               "expires_at": str(expires_at) if expires_at else None},
    )
    return row[0]


def attach(conn, guard_id, case_id, by):
    row = conn.execute(ATTACH, (case_id, guard_id)).fetchone()
    if row is None:
        return None

    audit.record(conn, "member_guard", guard_id, "attached", by,
                 before={"case_id": None}, after={"case_id": case_id})
    return guard_id


def set_expiry(conn, guard_id, expires_at, previous_expires_at, by):
    row = conn.execute(SET_EXPIRY, (expires_at, guard_id)).fetchone()
    if row is None:
        return None

    audit.record(conn, "member_guard", guard_id, "extended", by,
                 before={"expires_at": str(previous_expires_at) if previous_expires_at else None},
                 after={"expires_at": str(expires_at) if expires_at else None})
    return guard_id


def link(conn, action_id, guard_id):
    row = conn.execute(LINK, (guard_id, action_id)).fetchone()
    return row[0] if row else None


def apply_enforcement(conn, action_id, values, status, by):
    status = status or {}
    if not status.get("enforceable"):
        return None

    existing_guard = status.get("guard")
    case_id = status.get("case_id")
    choice = values.get("enforcement") or action.LOG_ONLY
    expires_at = action.expiry(values)

    if existing_guard is None:
        guard_id = open_guard(
            conn,
            action.guard_kind(values["type_key"]),
            values["target_user_id"],
            by,
            action.guard_reason(values),
            channel_id=values.get("channel_id")
            if action.guard_scope(values["type_key"]) == "channel"
            else None,
            case_id=case_id,
            expires_at=expires_at,
        )
    elif choice == action.ATTACH:
        guard_id = attach(conn, existing_guard["id"], case_id, by)
    elif choice == action.EXTEND:
        guard_id = set_expiry(conn, existing_guard["id"], expires_at, existing_guard.get("expires_at"), by)
    elif status.get("relation") == THIS_CASE:
        guard_id = existing_guard["id"]
    else:
        guard_id = None

    if guard_id:
        link(conn, action_id, guard_id)
    return guard_id


LIVE_GUARDS = """
SELECT id, kind, subject_id, channel_id, reason, expires_at, enforcement_status,
       enforced_by
FROM fd.member_guards
WHERE state = 'live' AND enforced_by <> 'firehose'
"""

UNENFORCED = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards
WHERE state = 'live' AND enforcement_status = 'pending' AND enforced_by = 'nemo'
ORDER BY opened_at LIMIT 20
"""

MARK_ENFORCED = """
UPDATE fd.member_guards
SET enforcement_status = 'held', dry_run = %s, attempts = 0, last_error = NULL, updated_at = now()
WHERE id = %s AND enforcement_status <> 'held'
RETURNING id
"""

MARK_FAILED = """
UPDATE fd.member_guards
SET enforcement_status = 'failed', attempts = attempts + 1, last_error = %s, updated_at = now()
WHERE id = %s
RETURNING attempts
"""

INSERT_EVENT = """
INSERT INTO fd.member_guard_events
    (guard_id, subject_id, channel_id, verb, message_ts, permalink, detail)
VALUES (%s, %s, %s, %s, %s, %s, %s)
RETURNING id
"""

RECENT_EVENT_COUNT = """
SELECT count(*) FROM fd.member_guard_events
WHERE guard_id = %s AND verb = %s AND at > now() - %s::interval
"""

LIVE_FIELDS = ("id", "kind", "subject_id", "channel_id", "reason", "expires_at",
               "enforcement_status", "enforced_by")

GUARD_FIELDS = ("id", "kind", "subject_id", "channel_id", "reason", "expires_at")

_shushes = {}
_bans = {}
_loaded = False
_lock = threading.Lock()


def refresh(conn):
    global _loaded
    shushes, bans = {}, {}
    for row in conn.execute(LIVE_GUARDS).fetchall():
        one = dict(zip(LIVE_FIELDS, row))
        if one["kind"] == SHUSH:
            shushes[one["subject_id"]] = one
        elif one["kind"] == CHANNEL_BAN:
            bans[(one["subject_id"], one["channel_id"])] = one

    with _lock:
        _shushes.clear()
        _shushes.update(shushes)
        _bans.clear()
        _bans.update(bans)
        _loaded = True
    return len(shushes) + len(bans)


def in_force(guard, now=None):
    expires_at = guard.get("expires_at")
    return expires_at is None or expires_at > (now or dt.datetime.now(dt.timezone.utc))


def active_shush(subject_id):
    with _lock:
        if not _loaded:
            return None
        guard = _shushes.get(subject_id)
    return guard if guard and in_force(guard) else None


def active_ban(subject_id, channel_id):
    with _lock:
        if not _loaded:
            return None
        guard = _bans.get((subject_id, channel_id))
    return guard if guard and in_force(guard) else None


def unenforced(conn):
    return [dict(zip(GUARD_FIELDS, row)) for row in conn.execute(UNENFORCED).fetchall()]


def mark_enforced(conn, guard_id, dry_run=False):
    return conn.execute(MARK_ENFORCED, (dry_run, guard_id)).fetchone() is not None


def mark_failed(conn, guard_id, why):
    row = conn.execute(MARK_FAILED, (why[:500], guard_id)).fetchone()
    return row[0] if row else None


def record_enforcement(conn, guard_id, subject_id, channel_id, verb,
             message_ts=None, permalink=None, detail=None):
    return conn.execute(
        INSERT_EVENT, (guard_id, subject_id, channel_id, verb, message_ts, permalink, detail)
    ).fetchone()[0]


RELEASE_EVENT_EXISTS = """
SELECT 1 FROM fd.member_guard_events WHERE guard_id = %s AND verb = 'released' LIMIT 1
"""

CLAIM_GUARD = "SELECT id FROM fd.member_guards WHERE id = %s FOR UPDATE"


def has_release_event(conn, guard_id):
    return conn.execute(RELEASE_EVENT_EXISTS, (guard_id,)).fetchone() is not None


def claim(conn, guard_id):
    return conn.execute(CLAIM_GUARD, (guard_id,)).fetchone() is not None


def count_recent_events(conn, guard_id, verb, within):
    return conn.execute(RECENT_EVENT_COUNT, (guard_id, verb, within)).fetchone()[0]


NEMO = "nemo"

BACKOFF_CAP = 30

LAPSED = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards
WHERE state = 'live' AND expires_at IS NOT NULL AND expires_at <= now()
  AND enforced_by <> 'firehose'
ORDER BY expires_at LIMIT 20
"""

FAILED_FOR_RETRY = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards
WHERE state = 'live' AND enforcement_status = 'failed' AND enforced_by = 'nemo'
  AND updated_at <= now() - (least(attempts, %s) * interval '1 minute')
ORDER BY updated_at LIMIT 20
"""

LIFT = """
UPDATE fd.member_guards
SET state = 'lifted', lifted_at = now(), lifted_by = %s, lift_reason = %s, updated_at = now()
WHERE id = %s AND state = 'live' AND enforced_by <> 'firehose'
RETURNING id
"""

START_LIFTING = """
UPDATE fd.member_guards
SET state = 'lifting', lifted_by = %s, lift_reason = %s, updated_at = now()
WHERE id = %s AND state = 'live' AND enforced_by <> 'firehose'
RETURNING id
"""

LIFT_DONE = """
UPDATE fd.member_guards
SET state = 'lifted', lifted_at = now(), updated_at = now()
WHERE id = %s AND state = 'lifting'
RETURNING id
"""

STILL_LIFTING = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards
WHERE state = 'lifting' AND enforced_by = 'nemo'
ORDER BY updated_at LIMIT 20
"""

ENDING_NOT_NOTIFIED = """
SELECT g.id, g.kind, g.subject_id, g.channel_id, g.reason, g.expires_at, g.case_id
FROM fd.member_guards g
WHERE g.state = 'live' AND g.expires_at IS NOT NULL AND g.enforced_by <> 'firehose'
  AND g.expires_at >= now() AND g.expires_at < now() + %s::interval
  AND NOT EXISTS (
    SELECT 1 FROM fd.member_guard_events e
    WHERE e.guard_id = g.id AND e.verb = 'notified' AND e.detail = %s
      AND e.at > now() - interval '20 hours'
  )
ORDER BY g.expires_at
"""


LIFTED_NOT_NOTIFIED = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards g
WHERE g.state = 'lifted' AND g.enforced_by = 'nemo'
  AND g.lifted_at > now() - %s::interval
  AND NOT EXISTS (
    SELECT 1 FROM fd.member_guard_events e
    WHERE e.guard_id = g.id AND e.verb = 'released'
  )
ORDER BY g.lifted_at
LIMIT 20
"""

RELEASED = "released"

NOTIFIED = "notified"

LIFTED_MANUALLY = "Lifted manually"


def lifted_not_notified(conn, within):
    return [dict(zip(GUARD_FIELDS, row)) for row in conn.execute(LIFTED_NOT_NOTIFIED, (within,)).fetchall()]


def lapsed(conn):
    return [dict(zip(GUARD_FIELDS, row)) for row in conn.execute(LAPSED).fetchall()]


def failed_for_retry(conn):
    return [
        dict(zip(GUARD_FIELDS, row))
        for row in conn.execute(FAILED_FOR_RETRY, (BACKOFF_CAP,)).fetchall()
    ]


def lifts_in_slack(kind):
    return kind in SLACK_LIFT_KINDS


def lift(conn, guard_id, by, why, kind=None):
    needs_slack_undo = lifts_in_slack(kind)
    sql = START_LIFTING if needs_slack_undo else LIFT
    row = conn.execute(sql, (by, why, guard_id)).fetchone()
    if row is None:
        return False

    new_state = "lifting" if needs_slack_undo else "lifted"
    audit.record(conn, "member_guard", guard_id, "lifted", by,
                 before={"state": "live"}, after={"state": new_state, "lift_reason": why})
    return True


def lift_done(conn, guard_id):
    return conn.execute(LIFT_DONE, (guard_id,)).fetchone() is not None


def still_lifting(conn):
    return [dict(zip(GUARD_FIELDS, row)) for row in conn.execute(STILL_LIFTING).fetchall()]


ENDING = "ending"


def ending_not_notified(conn, within):
    fields = (*GUARD_FIELDS, "case_id")
    return [
        dict(zip(fields, row))
        for row in conn.execute(ENDING_NOT_NOTIFIED, (within, ENDING)).fetchall()
    ]
