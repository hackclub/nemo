import logging

from psycopg.types.json import Jsonb

from bot.core import audit
from bot.core.case import reopen_reports
from bot.nemo import views

log = logging.getLogger("bot.nemo")


CASE_ASSIGNEES = """
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


def record_claim(conn, case_id, user_id):
    conn.execute(CLAIM, (case_id, user_id, user_id))
    audit.record(conn, "assignee", case_id, "claimed", user_id, after={"user_id": user_id})


OPEN_CASE = """
INSERT INTO fd.cases (opened_by, opened_at, source_app)
VALUES (%s, now(), %s)
RETURNING id
"""


OPENING = """
INSERT INTO fd.case_chat (case_id, author_user_id, body, source_app, mirrored_as)
VALUES (%s, %s, %s, %s, 'card')
"""


OPEN_CASES_FOR_SUBJECT = """
SELECT c.id FROM fd.cases c
JOIN fd.case_participants p ON p.case_id = c.id AND p.role = 'subject'
WHERE p.user_id = %s AND c.resolved_at IS NULL
ORDER BY c.opened_at
LIMIT 3
"""


MEMBER_NOTE = """
INSERT INTO fd.notes (subject_user_id, body, author) VALUES (%s, %s, %s) RETURNING id
"""


ADD_PARTICIPANT = """
INSERT INTO fd.case_participants (case_id, user_id, role)
VALUES (%s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING user_id
"""


INSERT_NOTE = """
INSERT INTO fd.notes (case_id, body, author) VALUES (%s, %s, %s) RETURNING id
"""


REMOVE_ASSIGNEE = """
DELETE FROM fd.case_assignees WHERE case_id = %s AND user_id = %s
RETURNING assigned_by
"""


REOPEN = """
UPDATE fd.cases
SET resolved_at = NULL, resolution = NULL, duplicate_of = NULL, updated_at = now()
WHERE id = %s AND resolved_at IS NOT NULL
RETURNING resolution
"""


SET_CATEGORY = """
UPDATE fd.cases c SET category_key = %s, updated_at = now()
FROM (SELECT category_key FROM fd.cases WHERE id = %s FOR UPDATE) previous
WHERE c.id = %s AND c.category_key IS DISTINCT FROM %s
RETURNING previous.category_key
"""


COPY_ASSIGNEES_TO_TARGET = """
INSERT INTO fd.case_assignees (case_id, user_id, assigned_by)
SELECT DISTINCT %s, a.user_id, %s FROM fd.case_assignees a
WHERE a.case_id = ANY(%s)
ON CONFLICT (case_id, user_id) DO NOTHING
RETURNING user_id
"""


LIVE_ACTIONS = """
SELECT id, target_user_id, type_key, expires_at, details FROM fd.actions
WHERE case_id = %s AND reversed_at IS NULL
ORDER BY performed_at, id
"""


RESOLUTION_LOG_ACTIONS = """
SELECT target_user_id, type_key, reason FROM fd.actions
WHERE case_id = %s AND reversed_at IS NULL
ORDER BY performed_at, id
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

CLOSE_REPORT = """
UPDATE fd.case_reports SET closed_at = now(), closed_by = %s
WHERE id = %s AND closed_at IS NULL
RETURNING case_id
"""


OPEN_REPORT = """
SELECT 1 FROM fd.case_reports WHERE case_id = %s AND closed_at IS NULL LIMIT 1
"""

PARENT = "SELECT duplicate_of FROM fd.cases WHERE id = %s"

FAMILY_HOPS = 10


def has_open_report(conn, case_id):
    return conn.execute(OPEN_REPORT, (case_id,)).fetchone() is not None


def family_root(conn, case_id):
    current = case_id
    for _ in range(FAMILY_HOPS):
        row = conn.execute(PARENT, (current,)).fetchone()
        if row is None or row[0] is None:
            return current
        current = row[0]
    return current


OPEN_CONVERSATION = """
SELECT id FROM fd.intake_conversations WHERE report_id = %s AND closed_at IS NULL
"""


QUEUE_OUTCOME = """
INSERT INTO fd.intake_outbox (conversation_id, kind, body, requested_by)
VALUES (%s, 'outcome', %s, %s)
"""


CASE_CATEGORY = "SELECT category_key FROM fd.cases WHERE id = %s"


LOG_ACTION = """
INSERT INTO fd.actions
    (case_id, type_key, target_user_id, decided_by, performed_by, performed_at,
     source_app, expires_at, details, reason, solution, resolved_by, category_key)
VALUES (%s, %s, %s, %s, %s, now(), %s, %s, %s, %s, %s, %s,
        coalesce(%s, (SELECT category_key FROM fd.cases WHERE id = %s)))
RETURNING id, performed_at, category_key
"""


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


def add_note(conn, case_id, body, by):
    note_id = conn.execute(INSERT_NOTE, (case_id, body, by)).fetchone()[0]
    audit.record(
        conn, "note", note_id, "noted", by,
        after={"case_id": case_id, "body": body},
    )
    return note_id


def assign_users(conn, case_id, user_ids, by):
    added = []
    for user_id in user_ids:
        row = conn.execute(ASSIGN, (case_id, user_id, by)).fetchone()
        if row is None:
            continue
        audit.record(conn, "assignee", case_id, "attached", by, after={"user_id": user_id})
        added.append(user_id)
    return added


def remove_assignee(conn, case_id, user_id, by):
    row = conn.execute(REMOVE_ASSIGNEE, (case_id, user_id)).fetchone()
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

    reopen_reports(conn, case_id, by)
    audit.record(
        conn, "case", case_id, "reopened", by,
        before={"resolution": row[0]},
        after={"resolved_at": None, "resolution": None},
    )
    return True


def set_category(conn, case_id, category_key, by):
    row = conn.execute(SET_CATEGORY, (category_key, case_id, case_id, category_key)).fetchone()
    if row is None:
        return False

    audit.record(
        conn, "case", case_id, "categorised", by,
        before={"category_key": row[0]}, after={"category_key": category_key},
    )
    return True


def open_cases_for_subject(conn, user_id):
    return [row[0] for row in conn.execute(OPEN_CASES_FOR_SUBJECT, (user_id,)).fetchall()]


def open_case(conn, subject, body, by):
    case_id = conn.execute(OPEN_CASE, (by, audit.SOURCE_APP)).fetchone()[0]
    audit.record(conn, "case", case_id, "opened", by, after={"opened_by": by})
    if subject:
        add_participants(conn, case_id, [subject], "subject", by)
    if body:
        conn.execute(OPENING, (case_id, by, body, audit.SOURCE_APP))
    return case_id


def member_note(conn, subject, body, by):
    note_id = conn.execute(MEMBER_NOTE, (subject, body, by)).fetchone()[0]
    audit.record(
        conn, "note", note_id, "noted", by,
        after={"subject_user_id": subject, "body": body},
    )
    return note_id


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


def resolution_log_actions(conn, case_id):
    return [
        {
            "target_user_id": row[0],
            "type_key": row[1],
            "reason": row[2],
        }
        for row in conn.execute(RESOLUTION_LOG_ACTIONS, (case_id,)).fetchall()
    ]


def close_reports(conn, case_id, values, user_id):
    notified = 0
    for row in conn.execute(CLOSE_REPORTS, (user_id, case_id)).fetchall():
        notified += report_closed(conn, row[0], case_id, values, user_id)
    return notified


def close_report(conn, report_id, values, user_id):
    row = conn.execute(CLOSE_REPORT, (user_id, report_id)).fetchone()
    if row is None:
        return 0
    return report_closed(conn, report_id, row[0], values, user_id)


def report_closed(conn, report_id, case_id, values, user_id):
    audit.record(
        conn, "report", report_id, "closed", user_id,
        before={"closed_at": None}, after={"closed_at": "now", "case_id": case_id},
    )
    open_conversation = conn.execute(OPEN_CONVERSATION, (report_id,)).fetchone()
    if open_conversation is None:
        return 0
    conn.execute(QUEUE_OUTCOME, (open_conversation[0], values, user_id))
    return 1


def resolve(conn, case_id, values, user_id):
    row = conn.execute(
        RESOLVE, (values["resolution"], values["member_note"], case_id)
    ).fetchone()
    if row is None:
        return None

    audit.record(
        conn, "case", case_id, "resolved", user_id,
        before={"resolved_at": None, "resolution": None},
        after={
            "resolved_at": str(row[0]),
            "resolution": values["resolution"],
            "member_note": values["member_note"],
        },
    )
    notified = close_reports(conn, case_id, values["message"], user_id) if values["notify_reporter"] else 0
    return notified


def log_action(conn, case_id, values, user_id):
    expires = views.action.expiry(values)
    row = conn.execute(
        LOG_ACTION,
        (
            case_id,
            values["type_key"],
            values["target_user_id"],
            user_id,
            user_id,
            audit.SOURCE_APP,
            expires,
            Jsonb(views.action.details(values)),
            values["reason"] or None,
            values.get("solution") or None,
            views.action.resolvers(values, user_id),
            values.get("category_key"),
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
            "type_key": values["type_key"],
            "target_user_id": values["target_user_id"],
            "expires_at": expires,
            "category_key": row[2],
            "solution": values.get("solution") or None,
            "resolved_by": views.action.resolvers(values, user_id),
        },
    )
    return row[0]


MERGE = """
UPDATE fd.cases
SET resolved_at = now(), resolution = 'duplicate', duplicate_of = %s, updated_at = now()
WHERE id = %s AND id <> %s AND resolved_at IS NULL
RETURNING resolved_at
"""


MERGEABLE = """
SELECT c.id, c.category_key,
       (SELECT string_agg(coalesce(m.display_name, m.handle, p.user_id), ', '
                          ORDER BY p.user_id)
          FROM fd.case_participants p
          LEFT JOIN fd.member m ON m.user_id = p.user_id
         WHERE p.case_id = c.id AND p.role = 'subject')
FROM fd.cases c
WHERE c.resolved_at IS NULL
ORDER BY c.id = ANY(%s) DESC, c.id DESC
LIMIT 100
"""


def mergeable(conn, preferred_ids=()):
    return conn.execute(MERGEABLE, (list(preferred_ids),)).fetchall()


def merge(conn, target_id, duplicate_ids, by):
    closed = []
    for case_id in sorted(set(duplicate_ids)):
        row = conn.execute(MERGE, (target_id, case_id, target_id)).fetchone()
        if row is None:
            continue
        audit.record(
            conn, "case", case_id, "resolved", by,
            before={"resolved_at": None, "resolution": None, "duplicate_of": None},
            after={"resolved_at": str(row[0]), "resolution": "duplicate", "duplicate_of": target_id},
        )
        closed.append(case_id)
    copy_assignees_to_target(conn, target_id, closed, by)
    return closed


def copy_assignees_to_target(conn, target_id, source_case_ids, by):
    if not source_case_ids:
        return []
    copied_user_ids = [
        row[0] for row in conn.execute(COPY_ASSIGNEES_TO_TARGET, (target_id, by, list(source_case_ids))).fetchall()
    ]
    for user_id in copied_user_ids:
        audit.record(conn, "assignee", target_id, "attached", by,
                     after={"user_id": user_id, "source_case_ids": list(source_case_ids)})
    return copied_user_ids


def default_resolution(conn, case_id):
    return "action_taken" if live_actions(conn, case_id) else "no_action"


def close_without_notice(conn, case_id, resolution, by):
    final_resolution = resolution or default_resolution(conn, case_id)
    values = {"resolution": final_resolution, "member_note": None, "message": None,
              "notify_reporter": False}
    return final_resolution if resolve(conn, case_id, values, by) is not None else None


def resolve_thread(conn, case_id, report_id, message, by):
    final_resolution = default_resolution(conn, case_id)
    values = {"resolution": final_resolution, "member_note": None, "message": message,
              "notify_reporter": False}
    resolved = resolve(conn, case_id, values, by) is not None
    notified = close_report(conn, report_id, message, by) if report_id else 0
    return (final_resolution if resolved else None), notified


def resolve_and_notify(conn, case_id, message, by):
    final_resolution = default_resolution(conn, case_id)
    values = {"resolution": final_resolution, "member_note": None, "message": message,
              "notify_reporter": True}
    notified = resolve(conn, case_id, values, by)
    if notified is not None:
        return final_resolution, notified
    return None, close_reports(conn, case_id, message, by)


def resolve_with_action(conn, case_id, values, by):
    if not values.get("resolve_case"):
        return None
    if values.get("notify_reporter") and has_open_report(conn, case_id):
        message = values.get("message") or views.resolve.default_message()
        resolution, _notified = resolve_and_notify(conn, case_id, message, by)
        return resolution
    return close_without_notice(conn, case_id, None, by)


MARK_RESOLUTION_LOG = "UPDATE fd.cases SET resolution_echo_by = %s WHERE id = %s"

PENDING_RESOLUTION_LOGS = "SELECT id FROM fd.cases WHERE resolution_echo_by IS NOT NULL"

RESOLUTION_LOG_DUE = """
WITH due AS (
    SELECT k.id, k.resolution_echo_by AS log_by, k.resolution, k.member_note
    FROM fd.cases k
    WHERE k.id = %(case_id)s AND k.resolution_echo_by IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM fd.intake_outbox o
          JOIN fd.intake_conversations c ON c.id = o.conversation_id
          JOIN fd.case_reports r ON r.id = c.report_id
          WHERE r.case_id = k.id AND o.kind = 'outcome' AND o.echoed_at IS NULL
      )
    FOR UPDATE
)
UPDATE fd.cases k SET resolution_echo_by = NULL
FROM due WHERE k.id = due.id
RETURNING due.log_by, due.resolution, due.member_note
"""


def mark_resolution_log_pending(conn, case_id, by):
    conn.execute(MARK_RESOLUTION_LOG, (by, case_id))


def pending_resolution_logs(conn):
    return [row[0] for row in conn.execute(PENDING_RESOLUTION_LOGS).fetchall()]


def resolution_log_due(conn, case_id):
    return conn.execute(RESOLUTION_LOG_DUE, {"case_id": case_id}).fetchone()
