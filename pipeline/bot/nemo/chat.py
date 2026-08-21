from psycopg.types.json import Jsonb

from bot.engine import parse

CASE_OF_THREAD = """
SELECT case_id FROM fd.case_reports WHERE forwarded_ts = %s
"""

KEEP = """
INSERT INTO fd.case_chat
    (case_id, author_user_id, body, blocks, said_at, channel_id, ts, thread_ts, source_app)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'nemo')
ON CONFLICT (channel_id, ts) WHERE ts IS NOT NULL
    DO UPDATE SET last_seen_at = now()
RETURNING id, (xmax = 0) AS inserted
"""

EDIT = """
UPDATE fd.case_chat
SET body = %s, blocks = %s, edited_at = %s, last_seen_at = now()
WHERE channel_id = %s AND ts = %s
RETURNING id
"""

DELETE = """
UPDATE fd.case_chat
SET deleted_at = now(), last_seen_at = now()
WHERE channel_id = %s AND ts = %s AND deleted_at IS NULL
RETURNING id
"""


def case_of_thread(conn, thread_ts):
    row = conn.execute(CASE_OF_THREAD, (thread_ts,)).fetchone()
    return row[0] if row else None


def keep(conn, case_id, event):
    blocks = event.get("blocks")
    row = conn.execute(
        KEEP,
        (
            case_id,
            event.get("user"),
            event.get("text"),
            Jsonb(blocks) if blocks else None,
            parse.posted_at(event["ts"]),
            event["channel"],
            event["ts"],
            event.get("thread_ts"),
        ),
    ).fetchone()
    return row[0], row[1]


def edit(conn, channel_id, message):
    edited = message.get("edited") or {}
    blocks = message.get("blocks")
    row = conn.execute(
        EDIT,
        (
            message.get("text"),
            Jsonb(blocks) if blocks else None,
            parse.posted_at(edited["ts"]) if edited.get("ts") else None,
            channel_id,
            message.get("ts"),
        ),
    ).fetchone()
    return row[0] if row else None


def delete(conn, channel_id, ts):
    row = conn.execute(DELETE, (channel_id, ts)).fetchone()
    return row[0] if row else None
