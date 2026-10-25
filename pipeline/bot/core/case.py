from bot.core import audit

CONVERSATION = """
SELECT c.report_id, r.case_id, c.member_user_id
FROM fd.intake_conversations c
LEFT JOIN fd.case_reports r ON r.id = c.report_id
WHERE c.id = %s
"""

FIRST_INBOUND = """
SELECT body, posted_at
FROM fd.intake_messages
WHERE conversation_id = %s AND direction = 'inbound'
ORDER BY posted_at, id
LIMIT 1
"""


def case_ref(conversation_id):
    return f"relay:conversation:{conversation_id}"


def report_ref(conversation_id):
    return f"relay:report:{conversation_id}"


RECORD_REPORTER_REPLY = """
UPDATE fd.cases SET reporter_replied_at = now()
WHERE id = %s AND resolved_at IS NOT NULL AND duplicate_of IS NULL AND reporter_replied_at IS NULL
RETURNING id
"""

REOPEN_REPORTS = """
UPDATE fd.case_reports r
SET closed_at = NULL, closed_by = NULL
FROM (
    SELECT id, closed_at, closed_by FROM fd.case_reports
    WHERE case_id = %s AND closed_at IS NOT NULL
) previous
WHERE r.id = previous.id
RETURNING r.id, previous.closed_at, previous.closed_by
"""


def reopen_reports(conn, case_id, by):
    rows = conn.execute(REOPEN_REPORTS, (case_id,)).fetchall()
    for report_id, closed_at, closed_by in rows:
        audit.record(
            conn, "report", report_id, "reopened", by,
            before={"closed_at": str(closed_at), "closed_by": closed_by},
            after={"closed_at": None, "closed_by": None, "case_id": case_id},
        )
    return [row[0] for row in rows]


def record_reporter_reply(conn, case_id):
    return conn.execute(RECORD_REPORTER_REPLY, (case_id,)).fetchone() is not None


def existing(conn, conversation_id):
    row = conn.execute(CONVERSATION, (conversation_id,)).fetchone()
    if row and row[0] and row[1]:
        return row[1]
    return None


DM = "dm"
SHORTCUT = "shortcut"

ADD_SUBJECT = """
INSERT INTO fd.case_participants (case_id, user_id, role)
VALUES (%s, %s, 'subject')
ON CONFLICT DO NOTHING
RETURNING user_id
"""


def add_subject(conn, case_id, user_id, by):
    if not conn.execute(ADD_SUBJECT, (case_id, user_id)).fetchone():
        return False
    audit.record(
        conn, "participant", case_id, "attached", by,
        after={"user_id": user_id, "role": "subject"},
    )
    return True


def open_case(conn, conversation_id, opened_by, anonymous=True, subject_user_id=None, entry_point=DM):
    already = existing(conn, conversation_id)
    if already:
        return already

    member = conn.execute(CONVERSATION, (conversation_id,)).fetchone()[2]
    reporter = None if anonymous else member

    ref = case_ref(conversation_id)
    conn.execute(
        "INSERT INTO fd.cases (opened_by, source_app, external_ref) "
        "VALUES (%s, 'relay', %s) ON CONFLICT (external_ref) DO NOTHING",
        (opened_by, ref),
    )
    case_id = conn.execute("SELECT id FROM fd.cases WHERE external_ref = %s", (ref,)).fetchone()[0]

    first = conn.execute(FIRST_INBOUND, (conversation_id,)).fetchone()
    body = first[0] if first else None
    received = first[1] if first else None

    report = report_ref(conversation_id)
    conn.execute(
        "INSERT INTO fd.case_reports "
        "(case_id, is_anonymous, reporter_user_id, body, received_at, source_app, external_ref, entry_point) "
        "VALUES (%s, %s, %s, %s, coalesce(%s, now()), 'relay', %s, %s) "
        "ON CONFLICT (external_ref) DO NOTHING",
        (case_id, reporter is None, reporter, body, received, report, entry_point),
    )
    report_id = conn.execute(
        "SELECT id FROM fd.case_reports WHERE external_ref = %s", (report,)
    ).fetchone()[0]

    conn.execute(
        "UPDATE fd.intake_conversations SET report_id = %s, handed_off_at = now() "
        "WHERE id = %s AND report_id IS NULL",
        (report_id, conversation_id),
    )
    if subject_user_id:
        add_subject(conn, case_id, subject_user_id, opened_by)
    return case_id
