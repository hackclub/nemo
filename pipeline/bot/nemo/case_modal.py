from bot.nemo import case_queue, channel, profile
from bot.nemo.views import case_view
from bot.nemo.views.activity import message_url

LIVE_ACTION_ENTRIES = """
SELECT type_key, target_user_id, expires_at, reason, performed_by, performed_at, details
FROM fd.actions
WHERE case_id = %s AND reversed_at IS NULL
ORDER BY performed_at, id
"""

CASE_NOTES = """
SELECT author, body, created_at
FROM fd.notes
WHERE case_id = %s AND deleted_at IS NULL
ORDER BY created_at, id
"""

CASE_THREADS = """
WITH RECURSIVE family(id) AS (
    SELECT %(case_id)s::bigint
    UNION
    SELECT c.id FROM fd.cases c JOIN family f ON c.duplicate_of = f.id
)
SELECT channel_id, thread_ts
FROM fd.case_threads
WHERE case_id IN (SELECT id FROM family) AND removed_at IS NULL
ORDER BY is_primary DESC, added_at, id
"""


def fetch_entries(conn, case_id):
    return [
        {
            "type_key": row[0],
            "target_user_id": row[1],
            "expires_at": row[2],
            "reason": row[3],
            "performed_by": row[4],
            "performed_at": row[5],
            "channel_id": (row[6] or {}).get("channel_id"),
        }
        for row in conn.execute(LIVE_ACTION_ENTRIES, (case_id,)).fetchall()
    ]


def fetch_notes(conn, case_id):
    return [
        {"author": row[0], "body": row[1], "created_at": row[2]}
        for row in conn.execute(CASE_NOTES, (case_id,)).fetchall()
    ]


def fetch_threads(conn, case_id):
    return [
        {"channel_id": row[0], "thread_ts": row[1]}
        for row in conn.execute(CASE_THREADS, {"case_id": case_id}).fetchall()
    ]


def has_report(case):
    return case.get("report_id") is not None


def reporter_of(client, case):
    if has_report(case) and case.get("is_anonymous"):
        return {"anonymous": True, "user_id": None, "icon": None}
    user_id = case.get("reporter_user_id") if has_report(case) else case.get("opened_by")
    icon = profile.profile(client, user_id)["icon"] if user_id and client else None
    return {"anonymous": False, "user_id": user_id, "icon": icon}


def thread_url_of(case):
    channel_id = case.get("card_channel_id")
    if not channel_id:
        return None
    ts = case.get("forwarded_ts") if has_report(case) else case.get("card_thread_ts") or case.get("card_ts")
    return message_url(channel_id, ts) if ts else None


def build(client, conn, case_id, notice=None):
    case = channel.fetch_case(conn, case_id) or case_queue.fetch_case(conn, case_id)
    if case is None:
        return None
    return case_view.build_view(
        case,
        reporter_of(client, case),
        fetch_entries(conn, case_id),
        fetch_notes(conn, case_id),
        thread_url_of(case),
        notice,
        fetch_threads(conn, case_id),
    )
