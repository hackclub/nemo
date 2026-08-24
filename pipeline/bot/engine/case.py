from bot.engine import audit

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
    return f"shroud:conversation:{conversation_id}"


def report_ref(conversation_id):
    return f"shroud:report:{conversation_id}"


STANDING = """
SELECT resolved_at, resolution, duplicate_of FROM fd.cases WHERE id = %s
"""

WAKE = """
UPDATE fd.cases SET resolved_at = NULL, resolution = NULL, updated_at = now()
WHERE id = %s AND resolved_at IS NOT NULL AND duplicate_of IS NULL
"""


def wake(conn, case_id, by):
    row = conn.execute(STANDING, (case_id,)).fetchone()
    if row is None or row[0] is None or row[2] is not None:
        return None

    was = row[1]
    conn.execute(WAKE, (case_id,))
    audit.record(
        conn,
        "case",
        case_id,
        "reopened",
        by,
        before={"resolved_at": str(row[0]), "resolution": was},
        after={
            "resolved_at": None,
            "resolution": None,
            "why": "the reporter wrote back",
        },
    )
    return was


def existing(conn, conversation_id):
    row = conn.execute(CONVERSATION, (conversation_id,)).fetchone()
    if row and row[0] and row[1]:
        return row[1]
    return None


def open_case(conn, conversation_id, opened_by, anonymous=True):
    already = existing(conn, conversation_id)
    if already:
        return already

    member = conn.execute(CONVERSATION, (conversation_id,)).fetchone()[2]
    reporter = None if anonymous else member

    ref = case_ref(conversation_id)
    conn.execute(
        "INSERT INTO fd.cases (opened_by, source_app, external_ref) "
        "VALUES (%s, 'shroud', %s) ON CONFLICT (external_ref) DO NOTHING",
        (opened_by, ref),
    )
    case_id = conn.execute("SELECT id FROM fd.cases WHERE external_ref = %s", (ref,)).fetchone()[0]

    first = conn.execute(FIRST_INBOUND, (conversation_id,)).fetchone()
    body = first[0] if first else None
    received = first[1] if first else None

    report = report_ref(conversation_id)
    conn.execute(
        "INSERT INTO fd.case_reports "
        "(case_id, is_anonymous, reporter_user_id, body, received_at, source_app, external_ref) "
        "VALUES (%s, %s, %s, %s, coalesce(%s, now()), 'shroud', %s) "
        "ON CONFLICT (external_ref) DO NOTHING",
        (case_id, reporter is None, reporter, body, received, report),
    )
    report_id = conn.execute(
        "SELECT id FROM fd.case_reports WHERE external_ref = %s", (report,)
    ).fetchone()[0]

    conn.execute(
        "UPDATE fd.intake_conversations SET report_id = %s, handed_off_at = now() "
        "WHERE id = %s AND report_id IS NULL",
        (report_id, conversation_id),
    )
    return case_id
