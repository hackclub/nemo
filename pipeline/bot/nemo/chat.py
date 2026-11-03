from psycopg.types.json import Jsonb

from bot.core import intake, parse
from bot.nemo.views import report as views

CASE_OF_THREAD = """
SELECT case_id FROM (
    SELECT case_id, 1 AS priority FROM fd.case_reports WHERE forwarded_ts = %(ts)s
    UNION ALL
    SELECT id, 2 FROM fd.cases WHERE card_thread_ts = %(ts)s
    UNION ALL
    SELECT id, 3 FROM fd.cases WHERE card_ts = %(ts)s AND card_thread_ts IS NULL
) matching_case
ORDER BY priority
LIMIT 1
"""

REPORT_OF_THREAD = """
SELECT id FROM fd.case_reports WHERE forwarded_ts = %s ORDER BY id LIMIT 1
"""

INSERT_CHAT = """
INSERT INTO fd.case_chat
    (case_id, author_user_id, body, blocks, posted_at, channel_id, ts, thread_ts, source_app)
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
  AND mirrored_ts IS NULL AND ts IS NULL AND posted_at > now() - interval '2 minutes'
ORDER BY posted_at
"""

ADOPT_PENDING = """
UPDATE fd.case_chat
SET channel_id = %s, ts = %s, mirrored_ts = %s, mirrored_at = now(), last_seen_at = now()
WHERE id = %s AND ts IS NULL
RETURNING id
"""


REPORTER_THREAD = """
SELECT 1 FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
WHERE m.mirrored_ts = %s
LIMIT 1
"""


def is_reporter_thread(conn, thread_ts):
    return conn.execute(REPORTER_THREAD, (thread_ts,)).fetchone() is not None


def case_of_thread(conn, thread_ts):
    row = conn.execute(CASE_OF_THREAD, {"ts": thread_ts}).fetchone()
    return row[0] if row else None


def report_of_thread(conn, thread_ts):
    row = conn.execute(REPORT_OF_THREAD, (thread_ts,)).fetchone()
    return row[0] if row else None


def attach_message(conn, case_id, event):
    row = conn.execute(ADOPT, (event["channel"], event["ts"], event["ts"])).fetchone()
    if row:
        return row[0]

    return attach_backfilled_message(conn, case_id, event)


def attach_backfilled_message(conn, case_id, event):
    text = event.get("text") or ""
    waiting = conn.execute(PENDING, (case_id, event.get("user"))).fetchall()
    for chat_id, body in waiting:
        if views.escape_but_mentions(body) != text:
            continue
        row = conn.execute(
            ADOPT_PENDING, (event["channel"], event["ts"], event["ts"], chat_id)
        ).fetchone()
        if row:
            return row[0]

    return None


def store_message(conn, case_id, event):
    attached_id = attach_message(conn, case_id, event)
    if attached_id:
        return attached_id, False

    return insert(conn, case_id, event)


def insert(conn, case_id, event):
    blocks = event.get("blocks")
    row = conn.execute(
        INSERT_CHAT,
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
    attach_files(conn, row[0], event)
    return row[0], row[1]


INSERT_CHAT_FILE = """
INSERT INTO fd.case_chat_files (chat_id, file_id, seq)
VALUES (%s, %s, %s) ON CONFLICT DO NOTHING
"""


def attach_files(conn, chat_id, event):
    for seq, item in enumerate(parse.files(event)):
        conn.execute(INSERT_CHAT_FILE, (chat_id, intake.store_file(conn, item), seq))


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


THREAD_TS_EXPRESSION = """
coalesce(
    (SELECT r.forwarded_ts FROM fd.case_reports r
      WHERE r.case_id = c.case_id AND r.forwarded_ts IS NOT NULL
      ORDER BY r.id LIMIT 1),
    (SELECT coalesce(k.card_thread_ts, k.card_ts) FROM fd.cases k WHERE k.id = c.case_id)
)
"""

WAITING = f"""
SELECT c.id, c.author_user_id, c.body, {THREAD_TS_EXPRESSION}
FROM fd.case_chat c
WHERE c.case_id = %s AND c.ts IS NULL AND c.mirrored_ts IS NULL
  AND c.mirrored_as IS DISTINCT FROM 'card'
  AND (c.mirrored_as IS NULL OR c.posted_at < now() - interval '2 minutes')
  AND {THREAD_TS_EXPRESSION} IS NOT NULL
ORDER BY c.posted_at, c.id
LIMIT 20
"""

WAITING_ANYWHERE = f"""
SELECT DISTINCT c.case_id
FROM fd.case_chat c
WHERE c.ts IS NULL AND c.mirrored_ts IS NULL
  AND c.mirrored_as IS DISTINCT FROM 'card'
  AND (c.mirrored_as IS NULL OR c.posted_at < now() - interval '2 minutes')
  AND {THREAD_TS_EXPRESSION} IS NOT NULL
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
