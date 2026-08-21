from psycopg.types.json import Jsonb

from bot.engine import parse
from bot.nemo.cards import report as cards

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


ADOPT = """
UPDATE fd.case_chat
SET channel_id = %s, ts = %s, last_seen_at = now()
WHERE mirrored_ts = %s AND ts IS NULL
RETURNING id
"""

PENDING = """
SELECT id, body FROM fd.case_chat
WHERE case_id = %s AND author_user_id = %s AND mirrored_as = 'user'
  AND mirrored_ts IS NULL AND ts IS NULL AND said_at > now() - interval '2 minutes'
ORDER BY said_at
"""

ADOPT_PENDING = """
UPDATE fd.case_chat
SET channel_id = %s, ts = %s, mirrored_ts = %s, mirrored_at = now(), last_seen_at = now()
WHERE id = %s AND ts IS NULL
RETURNING id
"""


def case_of_thread(conn, thread_ts):
    row = conn.execute(CASE_OF_THREAD, (thread_ts,)).fetchone()
    return row[0] if row else None


def adopt(conn, case_id, event):
    row = conn.execute(ADOPT, (event["channel"], event["ts"], event["ts"])).fetchone()
    if row:
        return row[0]

    return adopt_late(conn, case_id, event)


def adopt_late(conn, case_id, event):
    said = event.get("text") or ""
    waiting = conn.execute(PENDING, (case_id, event.get("user"))).fetchall()
    for chat_id, body in waiting:
        if cards.escape_but_mentions(body) != said:
            continue
        row = conn.execute(
            ADOPT_PENDING, (event["channel"], event["ts"], event["ts"], chat_id)
        ).fetchone()
        if row:
            return row[0]

    return None


def keep(conn, case_id, event):
    ours = adopt(conn, case_id, event)
    if ours:
        return ours, False

    return insert(conn, case_id, event)


def insert(conn, case_id, event):
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


WAITING = """
SELECT c.id, c.author_user_id, c.body, r.forwarded_ts
FROM fd.case_chat c
JOIN fd.case_reports r ON r.case_id = c.case_id
WHERE c.case_id = %s AND c.ts IS NULL AND c.mirrored_ts IS NULL
  AND (c.mirrored_as IS NULL OR c.said_at < now() - interval '2 minutes')
  AND r.forwarded_ts IS NOT NULL
ORDER BY c.said_at, c.id
LIMIT 20
"""

WAITING_ANYWHERE = """
SELECT DISTINCT c.case_id
FROM fd.case_chat c
JOIN fd.case_reports r ON r.case_id = c.case_id
WHERE c.ts IS NULL AND c.mirrored_ts IS NULL AND r.forwarded_ts IS NOT NULL
  AND (c.mirrored_as IS NULL OR c.said_at < now() - interval '2 minutes')
LIMIT 50
"""

MIRRORED = """
UPDATE fd.case_chat
SET mirrored_ts = %s, mirrored_at = now(), mirrored_as = 'nemo', last_seen_at = now()
WHERE id = %s AND mirrored_ts IS NULL
"""


def waiting(conn, case_id):
    return conn.execute(WAITING, (case_id,)).fetchall()


def waiting_anywhere(conn):
    return [row[0] for row in conn.execute(WAITING_ANYWHERE).fetchall()]


def mirrored(conn, chat_id, ts):
    conn.execute(MIRRORED, (ts, chat_id))
