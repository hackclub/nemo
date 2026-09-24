import logging

from psycopg.types.json import Jsonb

from bot.core import audit
from bot.nemo import cards

log = logging.getLogger("bot.nemo")


HELD_BY = """
SELECT user_id FROM fd.case_assignees WHERE case_id = %s ORDER BY assigned_at
"""


CLAIM = """
INSERT INTO fd.case_assignees (case_id, user_id, assigned_by) VALUES (%s, %s, %s)
ON CONFLICT DO NOTHING
"""


ASSIGN = """
INSERT INTO fd.case_assignees (case_id, user_id, assigned_by) VALUES (%s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING user_id
"""


STILL_OPEN = """
SELECT resolved_at IS NULL FROM fd.cases WHERE id = %s
"""


def claimed(conn, case_id, user_id):
    conn.execute(CLAIM, (case_id, user_id, user_id))
    audit.record(conn, "assignee", case_id, "claimed", user_id, after={"user_id": user_id})


OPEN_CASE = """
INSERT INTO fd.cases (opened_by, opened_at, source_app)
VALUES (%s, now(), %s)
RETURNING id
"""


OPEN_ABOUT = """
SELECT c.id FROM fd.cases c
JOIN fd.case_participants p ON p.case_id = c.id AND p.role = 'subject'
WHERE p.user_id = %s AND c.resolved_at IS NULL
ORDER BY c.opened_at
LIMIT 3
"""


MEMBER_NOTE = """
INSERT INTO fd.notes (subject_user_id, body, author) VALUES (%s, %s, %s) RETURNING id
"""


PARTICIPANTS = """
SELECT user_id, role, detail FROM fd.case_participants
WHERE case_id = %s ORDER BY noted_at
"""


ADD_PARTICIPANT = """
INSERT INTO fd.case_participants (case_id, user_id, role)
VALUES (%s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING user_id
"""


REMOVE_PARTICIPANT = """
DELETE FROM fd.case_participants WHERE case_id = %s AND user_id = %s AND role = %s
RETURNING detail
"""


SET_CATEGORY = """
UPDATE fd.cases SET category_key = %s, updated_at = now()
WHERE id = %s AND category_key IS NULL
RETURNING category_key
"""


KEEP_NOTE = """
INSERT INTO fd.notes (case_id, body, author) VALUES (%s, %s, %s) RETURNING id
"""


HAND_BACK = """
DELETE FROM fd.case_assignees WHERE case_id = %s AND user_id = %s
RETURNING assigned_by
"""


REOPEN = """
UPDATE fd.cases
SET resolved_at = NULL, resolution = NULL, duplicate_of = NULL, updated_at = now()
WHERE id = %s AND resolved_at IS NOT NULL
RETURNING resolution
"""


CLEAR_ASSIGNEES = """
DELETE FROM fd.case_assignees WHERE case_id = %s RETURNING user_id
"""


LIVE_ACTIONS = """
SELECT id, target_user_id, type_key, expires_at, details FROM fd.actions
WHERE case_id = %s AND reversed_at IS NULL
ORDER BY performed_at, id
"""


OPEN_REPORTS = """
SELECT count(*) FROM fd.case_reports WHERE case_id = %s AND closed_at IS NULL
"""


RESOLVE = """
UPDATE fd.cases SET resolved_at = now(), resolution = %s, member_note = %s, updated_at = now()
WHERE id = %s AND resolved_at IS NULL
RETURNING resolved_at
"""


CLOSE_REPORTS = """
UPDATE fd.case_reports SET closed_at = now(), closed_by = %s
WHERE case_id = %s AND closed_at IS NULL
RETURNING id
"""


OPEN_CONVERSATION = """
SELECT id FROM fd.intake_conversations WHERE report_id = %s AND closed_at IS NULL
"""


TELL_THEM = """
INSERT INTO fd.intake_outbox (conversation_id, kind, body, requested_by)
VALUES (%s, 'outcome', %s, %s)
"""


CASE_CATEGORY = "SELECT category_key FROM fd.cases WHERE id = %s"


LOG_ACTION = """
INSERT INTO fd.actions
    (case_id, type_key, target_user_id, decided_by, performed_by, performed_at,
     source_app, expires_at, details, reason, category_key)
VALUES (%s, %s, %s, %s, %s, now(), %s, %s, %s, %s,
        coalesce(%s, (SELECT category_key FROM fd.cases WHERE id = %s)))
RETURNING id, performed_at, category_key
"""


def participants(conn, case_id):
    return [
        {"user_id": row[0], "role": row[1], "detail": row[2]}
        for row in conn.execute(PARTICIPANTS, (case_id,)).fetchall()
    ]


def add_participants(conn, case_id, user_ids, role, by):
    added = []
    for user_id in user_ids:
        row = conn.execute(ADD_PARTICIPANT, (case_id, user_id, role)).fetchone()
        if row is None:
            continue
        audit.record(
            conn, "participant", case_id, "attached", by,
            after={"user_id": user_id, "role": role},
        )
        added.append(user_id)
    return added


def remove_participant(conn, case_id, user_id, role, by):
    row = conn.execute(REMOVE_PARTICIPANT, (case_id, user_id, role)).fetchone()
    if row is None:
        return False

    audit.record(
        conn, "participant", case_id, "detached", by,
        before={"user_id": user_id, "role": role, "detail": row[0]},
        after=None,
    )
    return True


def set_category(conn, case_id, key, by):
    row = conn.execute(SET_CATEGORY, (key, case_id)).fetchone()
    if row is None:
        return False

    audit.record(
        conn, "case", case_id, "categorised", by,
        before={"category_key": None}, after={"category_key": key},
    )
    return True


def keep_note(conn, case_id, body, by):
    note_id = conn.execute(KEEP_NOTE, (case_id, body, by)).fetchone()[0]
    audit.record(
        conn, "note", note_id, "noted", by,
        after={"case_id": case_id, "body": body},
    )
    return note_id


def assign_people(conn, case_id, user_ids, by):
    added = []
    for user_id in user_ids:
        row = conn.execute(ASSIGN, (case_id, user_id, by)).fetchone()
        if row is None:
            continue
        audit.record(conn, "assignee", case_id, "attached", by, after={"user_id": user_id})
        added.append(user_id)
    return added


def remove_assignee(conn, case_id, user_id, by):
    row = conn.execute(HAND_BACK, (case_id, user_id)).fetchone()
    if row is None:
        return False

    audit.record(
        conn, "assignee", case_id, "detached", by,
        before={"user_id": user_id, "assigned_by": row[0]}, after=None,
    )
    return True


def reopen(conn, case_id, by):
    row = conn.execute(REOPEN, (case_id,)).fetchone()
    if row is None:
        return False

    held = [one[0] for one in conn.execute(CLEAR_ASSIGNEES, (case_id,)).fetchall()]
    audit.record(
        conn, "case", case_id, "reopened", by,
        before={"resolution": row[0], "assignees": held},
        after={"resolved_at": None, "resolution": None, "assignees": []},
    )
    return True


def open_about(conn, user_id):
    return [row[0] for row in conn.execute(OPEN_ABOUT, (user_id,)).fetchall()]


def open_case(conn, subject, body, by):
    case_id = conn.execute(OPEN_CASE, (by, audit.SOURCE_APP)).fetchone()[0]
    audit.record(conn, "case", case_id, "opened", by, after={"opened_by": by})
    if subject:
        add_participants(conn, case_id, [subject], "subject", by)
    if body:
        keep_note(conn, case_id, body, by)
    return case_id


def member_note(conn, subject, body, by):
    note_id = conn.execute(MEMBER_NOTE, (subject, body, by)).fetchone()[0]
    audit.record(
        conn, "note", note_id, "noted", by,
        after={"subject_user_id": subject, "body": body},
    )
    return note_id


def counted(conn, sql, case_id):
    return conn.execute(sql, (case_id,)).fetchone()[0]


def live_actions(conn, case_id):
    return [
        {
            "id": row[0],
            "target_user_id": row[1],
            "type_key": row[2],
            "expires_at": row[3],
            "details": row[4],
        }
        for row in conn.execute(LIVE_ACTIONS, (case_id,)).fetchall()
    ]


def close_reports(conn, case_id, said, user_id):
    told = 0
    for row in conn.execute(CLOSE_REPORTS, (user_id, case_id)).fetchall():
        report_id = row[0]
        audit.record(
            conn, "report", report_id, "closed", user_id,
            before={"closed_at": None}, after={"closed_at": "now", "case_id": case_id},
        )
        open_one = conn.execute(OPEN_CONVERSATION, (report_id,)).fetchone()
        if open_one is None:
            continue
        conn.execute(TELL_THEM, (open_one[0], said, user_id))
        told += 1
    return told


def resolve(conn, case_id, said, user_id):
    row = conn.execute(
        RESOLVE, (said["resolution"], said["member_note"], case_id)
    ).fetchone()
    if row is None:
        return None

    audit.record(
        conn, "case", case_id, "resolved", user_id,
        before={"resolved_at": None, "resolution": None},
        after={
            "resolved_at": str(row[0]),
            "resolution": said["resolution"],
            "member_note": said["member_note"],
        },
    )
    told = close_reports(conn, case_id, said["said"], user_id) if said["telling"] else 0
    return told


REVERSE_ACTION = """
UPDATE fd.actions SET reversed_at = now(), reversed_by = %s, reversal_reason = %s
WHERE id = %s AND case_id = %s AND reversed_at IS NULL
RETURNING reversed_at
"""


def reverse_action(conn, case_id, action_id, reason, user_id):
    row = conn.execute(REVERSE_ACTION, (user_id, reason, action_id, case_id)).fetchone()
    if row is None:
        return False

    audit.record(
        conn,
        "action",
        action_id,
        "reversed",
        user_id,
        before={"reversed_at": None},
        after={"reversed_at": str(row[0]), "reversed_by": user_id, "reason": reason},
    )
    return True


def log_action(conn, case_id, said, user_id):
    expires = f"{said['expires_on']} 23:59:59" if said.get("expires_on") else None
    row = conn.execute(
        LOG_ACTION,
        (
            case_id,
            said["type_key"],
            said["target_user_id"],
            user_id,
            user_id,
            audit.SOURCE_APP,
            expires,
            Jsonb(cards.action.details(said)),
            said["reason"],
            said.get("category_key"),
            case_id,
        ),
    ).fetchone()

    audit.record(
        conn,
        "action",
        row[0],
        "performed",
        user_id,
        after={
            "case_id": case_id,
            "type_key": said["type_key"],
            "target_user_id": said["target_user_id"],
            "expires_at": expires,
            "category_key": row[2],
        },
    )
    return row[0]
