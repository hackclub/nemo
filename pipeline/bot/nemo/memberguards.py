import threading

from bot.core import audit
from bot.nemo.cards import action

SHUSH = "shush"
CHANNEL_BAN = "channel_ban"
DEACTIVATION = "deactivation"

UNDONE_IN_SLACK = (DEACTIVATION,)

UNGUARDED = action.UNGUARDED
ORPHANED = action.ORPHANED
ELSEWHERE = action.ELSEWHERE
HERE = action.HERE

FIELDS = (
    "id", "kind", "subject_id", "channel_id", "state", "carry", "carried_by",
    "case_id", "opened_by", "opened_at", "reason", "expires_at",
)

COLUMNS = ", ".join(FIELDS)

STANDING = f"""
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


def seen(row):
    return dict(zip(FIELDS, row)) if row else None


def enforceable(type_key):
    return action.guard_kind(type_key) is not None


def standing(conn, subject_id, kind, channel_id=None):
    return seen(conn.execute(STANDING, (subject_id, kind, channel_id)).fetchone())


def for_member(conn, subject_id):
    return [seen(row) for row in conn.execute(FOR_MEMBER, (subject_id,)).fetchall()]


def on_case(conn, case_id):
    return [seen(row) for row in conn.execute(ON_CASE, (case_id,)).fetchall()]


def for_action(conn, type_key, subject_id, channel_id=None):
    kind = action.guard_kind(type_key)
    if kind is None:
        return None
    if action.guard_scope(type_key) != "channel":
        channel_id = None
    return standing(conn, subject_id, kind, channel_id)


def settle(conn, type_key, subject_id, case_id=None, channel_id=None):
    if not enforceable(type_key):
        return {"enforceable": False, "found": None, "reads": UNGUARDED, "case_id": case_id}
    if not subject_id:
        return {"enforceable": True, "found": None, "reads": UNGUARDED, "case_id": case_id}

    found = for_action(conn, type_key, subject_id, channel_id)
    return {
        "enforceable": True,
        "found": found,
        "reads": reads(found, case_id),
        "case_id": case_id,
    }


def reads(found, case_id=None):
    if found is None:
        return UNGUARDED
    if found["case_id"] is None:
        return ORPHANED
    if case_id is not None and found["case_id"] == case_id:
        return HERE
    return ELSEWHERE


OPEN = """
INSERT INTO fd.member_guards
    (kind, subject_id, channel_id, case_id, opened_by, reason, expires_at,
     carried_by, carry)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING id
"""

ATTACH = """
UPDATE fd.member_guards SET case_id = %s, updated_at = now()
WHERE id = %s AND case_id IS NULL AND state IN ('live', 'lifting')
RETURNING id
"""

RUN_UNTIL = """
UPDATE fd.member_guards SET expires_at = %s, updated_at = now()
WHERE id = %s AND state IN ('live', 'lifting')
RETURNING id
"""

LINK = """
UPDATE fd.actions SET guard_id = %s WHERE id = %s AND guard_id IS NULL RETURNING id
"""


def open_guard(conn, kind, subject_id, by, reason, channel_id=None, case_id=None,
               expires_at=None, by_hand=False):
    carried_by, carry = ("by_hand", "held") if by_hand else ("nemo", "pending")
    row = conn.execute(
        OPEN,
        (kind, subject_id, channel_id, case_id, by, reason, expires_at, carried_by, carry),
    ).fetchone()
    if row is None:
        return None

    audit.record(
        conn, "member_guard", row[0], "opened", by,
        after={"kind": kind, "subject_id": subject_id, "channel_id": channel_id,
               "case_id": case_id, "carried_by": carried_by,
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


def run_until(conn, guard_id, expires_at, was, by):
    row = conn.execute(RUN_UNTIL, (expires_at, guard_id)).fetchone()
    if row is None:
        return None

    audit.record(conn, "member_guard", guard_id, "extended", by,
                 before={"expires_at": str(was) if was else None},
                 after={"expires_at": str(expires_at) if expires_at else None})
    return guard_id


def link(conn, action_id, guard_id):
    row = conn.execute(LINK, (guard_id, action_id)).fetchone()
    return row[0] if row else None


def settled(conn, action_id, said, standing, by):
    standing = standing or {}
    if not standing.get("enforceable"):
        return None

    found = standing.get("found")
    case_id = standing.get("case_id")
    chose = said.get("settle") or action.RECORD
    expires_at = action.expiry(said)

    if found is None:
        guard_id = open_guard(
            conn,
            action.guard_kind(said["type_key"]),
            said["target_user_id"],
            by,
            said["reason"],
            channel_id=said.get("channel_id")
            if action.guard_scope(said["type_key"]) == "channel"
            else None,
            case_id=case_id,
            expires_at=expires_at,
        )
    elif chose == action.ADOPT:
        guard_id = attach(conn, found["id"], case_id, by)
    elif chose == action.EXTEND:
        guard_id = run_until(conn, found["id"], expires_at, found.get("expires_at"), by)
    elif standing.get("reads") == HERE:
        guard_id = found["id"]
    else:
        guard_id = None

    if guard_id:
        link(conn, action_id, guard_id)
    return guard_id


LIVE_GUARDS = """
SELECT id, kind, subject_id, channel_id, reason, expires_at, carry, carried_by
FROM fd.member_guards
WHERE state = 'live'
"""

UNCARRIED = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards
WHERE state = 'live' AND carry = 'pending' AND carried_by = 'nemo'
ORDER BY opened_at LIMIT 20
"""

HOLDING = """
UPDATE fd.member_guards
SET carry = 'held', attempts = 0, last_error = NULL, updated_at = now()
WHERE id = %s AND carry <> 'held'
RETURNING id
"""

DROPPED = """
UPDATE fd.member_guards
SET carry = 'failed', attempts = attempts + 1, last_error = %s, updated_at = now()
WHERE id = %s
RETURNING attempts
"""

HAPPENED = """
INSERT INTO fd.member_guard_events
    (guard_id, subject_id, channel_id, verb, message_ts, permalink, detail)
VALUES (%s, %s, %s, %s, %s, %s, %s)
RETURNING id
"""

LATELY = """
SELECT count(*) FROM fd.member_guard_events
WHERE guard_id = %s AND verb = %s AND at > now() - %s::interval
"""

WATCHED = ("id", "kind", "subject_id", "channel_id", "reason", "expires_at",
           "carry", "carried_by")

WANTED = ("id", "kind", "subject_id", "channel_id", "reason", "expires_at")

_shushes = {}
_bans = {}
_loaded = False
_lock = threading.Lock()


def refresh(conn):
    global _loaded
    shushes, bans = {}, {}
    for row in conn.execute(LIVE_GUARDS).fetchall():
        one = dict(zip(WATCHED, row))
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


def shushed(subject_id):
    with _lock:
        if not _loaded:
            return None
        return _shushes.get(subject_id)


def banned(subject_id, channel_id):
    with _lock:
        if not _loaded:
            return None
        return _bans.get((subject_id, channel_id))


def uncarried(conn):
    return [dict(zip(WANTED, row)) for row in conn.execute(UNCARRIED).fetchall()]


def holding(conn, guard_id):
    return conn.execute(HOLDING, (guard_id,)).fetchone() is not None


def dropped(conn, guard_id, why):
    row = conn.execute(DROPPED, (why[:500], guard_id)).fetchone()
    return row[0] if row else None


def happened(conn, guard_id, subject_id, channel_id, verb,
             message_ts=None, permalink=None, detail=None):
    return conn.execute(
        HAPPENED, (guard_id, subject_id, channel_id, verb, message_ts, permalink, detail)
    ).fetchone()[0]


def lately(conn, guard_id, verb, within):
    return conn.execute(LATELY, (guard_id, verb, within)).fetchone()[0]


NEMO = "nemo"

BACKOFF_CAP = 30

LAPSED = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards
WHERE state = 'live' AND expires_at IS NOT NULL AND expires_at <= now()
ORDER BY expires_at LIMIT 20
"""

DROPPED_AWHILE = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards
WHERE state = 'live' AND carry = 'failed' AND carried_by = 'nemo'
  AND updated_at <= now() - (least(attempts, %s) * interval '1 minute')
ORDER BY updated_at LIMIT 20
"""

LET_GO = """
UPDATE fd.member_guards
SET state = 'lifted', lifted_at = now(), lifted_by = %s, lift_reason = %s, updated_at = now()
WHERE id = %s AND state = 'live'
RETURNING id
"""

START_LIFTING = """
UPDATE fd.member_guards
SET state = 'lifting', lifted_by = %s, lift_reason = %s, updated_at = now()
WHERE id = %s AND state = 'live'
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
WHERE state = 'lifting' AND carried_by = 'nemo'
ORDER BY updated_at LIMIT 20
"""

ENDING_UNTOLD = """
SELECT g.id, g.kind, g.subject_id, g.channel_id, g.reason, g.expires_at, g.case_id
FROM fd.member_guards g
WHERE g.state = 'live' AND g.expires_at IS NOT NULL
  AND g.expires_at >= now() AND g.expires_at < now() + %s::interval
  AND NOT EXISTS (
    SELECT 1 FROM fd.member_guard_events e
    WHERE e.guard_id = g.id AND e.verb = 'told' AND e.detail = %s
      AND e.at > now() - interval '20 hours'
  )
ORDER BY g.expires_at
"""


LIFTED_UNTOLD = """
SELECT id, kind, subject_id, channel_id, reason, expires_at
FROM fd.member_guards g
WHERE g.state = 'lifted' AND g.carried_by = 'nemo'
  AND g.lifted_at > now() - %s::interval
  AND NOT EXISTS (
    SELECT 1 FROM fd.member_guard_events e
    WHERE e.guard_id = g.id AND e.verb = 'released'
  )
ORDER BY g.lifted_at
LIMIT 20
"""

RELEASED = "released"

LIFTED_BY_HAND = "somebody lifted it"


def lifted_untold(conn, within):
    return [dict(zip(WANTED, row)) for row in conn.execute(LIFTED_UNTOLD, (within,)).fetchall()]


def lapsed(conn):
    return [dict(zip(WANTED, row)) for row in conn.execute(LAPSED).fetchall()]


def dropped_awhile(conn):
    return [
        dict(zip(WANTED, row))
        for row in conn.execute(DROPPED_AWHILE, (BACKOFF_CAP,)).fetchall()
    ]


def undone_in_slack(kind):
    return kind in UNDONE_IN_SLACK


def let_go(conn, guard_id, by, why, kind=None):
    waiting = undone_in_slack(kind)
    sql = START_LIFTING if waiting else LET_GO
    row = conn.execute(sql, (by, why, guard_id)).fetchone()
    if row is None:
        return False

    landed = "lifting" if waiting else "lifted"
    audit.record(conn, "member_guard", guard_id, "lifted", by,
                 before={"state": "live"}, after={"state": landed, "lift_reason": why})
    return True


GUARD_STILL_WANTED = """
SELECT g.id, g.kind
FROM fd.member_guards g
JOIN fd.actions a ON a.guard_id = g.id
WHERE a.id = %s AND g.state = 'live'
  AND NOT EXISTS (
    SELECT 1 FROM fd.actions o WHERE o.guard_id = g.id AND o.reversed_at IS NULL
  )
"""


def lift_for_action(conn, action_id, by, why):
    row = conn.execute(GUARD_STILL_WANTED, (action_id,)).fetchone()
    if row is None:
        return None

    guard_id, kind = row
    return guard_id if let_go(conn, guard_id, by, why, kind=kind) else None


def lift_done(conn, guard_id):
    return conn.execute(LIFT_DONE, (guard_id,)).fetchone() is not None


def still_lifting(conn):
    return [dict(zip(WANTED, row)) for row in conn.execute(STILL_LIFTING).fetchall()]


ENDING = "ending"


def ending_untold(conn, within):
    fields = (*WANTED, "case_id")
    return [
        dict(zip(fields, row))
        for row in conn.execute(ENDING_UNTOLD, (within, ENDING)).fetchall()
    ]
