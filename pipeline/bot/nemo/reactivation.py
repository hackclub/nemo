from bot.core import audit
from bot.nemo import memberguards
from bot.nemo.views import action as action_view

QUEUED = "queued"
LIFTED = "lifted"
FIREHOSE = "firehose"
NOTHING = "nothing"

STANDING = """
SELECT id, enforced_by, state FROM fd.member_guards
WHERE subject_id = %s AND kind = 'deactivation' AND state IN ('live', 'lifting')
ORDER BY id DESC
LIMIT 1
"""

DEACTIVATED = "SELECT deactivated FROM fd.member_account WHERE user_id = %s"

RECORD = """
INSERT INTO fd.member_guards
    (kind, subject_id, opened_by, opened_at, reason, case_id, enforced_by, enforcement_status, lift_only)
VALUES ('deactivation', %s, %s, coalesce(%s, now()), %s, %s, 'nemo', 'held', true)
ON CONFLICT DO NOTHING
RETURNING id
"""

LATEST_BAN = """
SELECT performed_by, performed_at, reason, case_id, type_key FROM fd.actions
WHERE target_user_id = %s AND reversed_at IS NULL AND type_key = ANY(%s)
  AND (expires_at IS NULL OR expires_at > now())
ORDER BY performed_at DESC, id DESC
LIMIT 1
"""

OUTSIDE_NEMO = "Deactivated outside Nemo"

RUNNING_BANS = """
SELECT id, expires_at FROM fd.actions
WHERE target_user_id = %s AND reversed_at IS NULL AND type_key = ANY(%s)
  AND (expires_at IS NULL OR expires_at > now())
ORDER BY id
FOR UPDATE
"""

END_BAN = "UPDATE fd.actions SET expires_at = now() WHERE id = %s RETURNING expires_at"


def account_bans():
    return [key for key in action_view.table() if action_view.deactivates(key)]


def stamp(value):
    return str(value) if value else None


def is_deactivated(conn, user_id):
    row = conn.execute(DEACTIVATED, (user_id,)).fetchone()
    return bool(row and row[0])


def running_bans(conn, user_id):
    return conn.execute(RUNNING_BANS, (user_id, account_bans())).fetchall()


def record_deactivation(conn, user_id, by):
    ban = conn.execute(LATEST_BAN, (user_id, account_bans())).fetchone()
    if ban:
        opened_by, opened_at, reason, case_id, type_key = ban
        reason = reason or action_view.label(type_key)
    else:
        opened_by, opened_at, reason, case_id = by, None, OUTSIDE_NEMO, None
    row = conn.execute(RECORD, (user_id, opened_by, opened_at, reason, case_id)).fetchone()
    if row is None:
        return None
    return (row[0], memberguards.NEMO, "live")


def lift(conn, guard, by, why):
    guard_id, enforced_by, state = guard
    if enforced_by == memberguards.FIREHOSE:
        return FIREHOSE
    in_slack = enforced_by == memberguards.NEMO
    if state == "lifting":
        return QUEUED
    lifted = memberguards.lift(conn, guard_id, by, why, kind=memberguards.DEACTIVATION if in_slack else None)
    if not lifted:
        return NOTHING
    return QUEUED if in_slack else LIFTED


def end_running_bans(conn, user_id, by, why):
    ended = []
    for action_id, expires_at in running_bans(conn, user_id):
        row = conn.execute(END_BAN, (action_id,)).fetchone()
        audit.record(conn, "action", action_id, "ended", by, subject_user_id=user_id,
                     before={"expires_at": stamp(expires_at)},
                     after={"expires_at": stamp(row[0] if row else None), "reason": why})
        ended.append(action_id)
    return ended


def reactivate(conn, user_id, by, why, end_bans=True):
    guard = conn.execute(STANDING, (user_id,)).fetchone()
    if guard is None and is_deactivated(conn, user_id):
        guard = record_deactivation(conn, user_id, by)
    outcome = lift(conn, guard, by, why) if guard else NOTHING
    if outcome == FIREHOSE:
        return outcome, []
    ended = end_running_bans(conn, user_id, by, why) if end_bans else []
    return outcome, ended
