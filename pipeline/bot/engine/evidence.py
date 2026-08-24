from bot.engine import audit

SHARED = """
SELECT s.source_channel_id,
       coalesce(s.source_thread_ts, s.source_ts) AS thread_ts,
       s.source_ts,
       s.source_author_user_id,
       s.source_body,
       s.permalink
FROM fd.intake_shares s
JOIN fd.intake_messages m ON m.id = s.message_id
WHERE m.conversation_id = %s
  AND m.direction = 'inbound'
  AND s.is_reachable
  AND s.source_channel_id IS NOT NULL
  AND s.source_ts IS NOT NULL
ORDER BY s.id
"""

ATTACH = """
INSERT INTO fd.case_threads (case_id, channel_id, thread_ts, kind, is_primary, added_by)
SELECT %(case_id)s, %(channel_id)s, %(thread_ts)s, 'evidence',
       NOT EXISTS (
         SELECT 1 FROM fd.case_threads WHERE case_id = %(case_id)s AND is_primary
       ),
       %(added_by)s
ON CONFLICT (case_id, channel_id, thread_ts) DO NOTHING
RETURNING id, is_primary
"""


KEEP = """
INSERT INTO fd.thread_messages
    (channel_id, thread_ts, message_ts, parent_ts, is_root,
     author_user_id, body, permalink, posted_at, source_app)
VALUES (%(channel_id)s, %(thread_ts)s, %(message_ts)s::text, %(parent_ts)s, %(is_root)s,
        %(author)s, %(body)s, %(permalink)s,
        to_timestamp(%(message_ts)s::text::numeric), 'shroud')
ON CONFLICT (channel_id, thread_ts, message_ts) DO NOTHING
RETURNING id
"""


def shared(conn, conversation_id):
    return [
        {
            "channel_id": row[0],
            "thread_ts": row[1],
            "source_ts": row[2],
            "author": row[3],
            "body": row[4],
            "permalink": row[5],
        }
        for row in conn.execute(SHARED, (conversation_id,)).fetchall()
    ]


def keep(conn, found):
    if not found.get("author"):
        return None

    at_root = found["source_ts"] == found["thread_ts"]
    row = conn.execute(
        KEEP,
        {
            "channel_id": found["channel_id"],
            "thread_ts": found["thread_ts"],
            "message_ts": found["source_ts"],
            "parent_ts": None if at_root else found["thread_ts"],
            "is_root": at_root,
            "author": found["author"],
            "body": found["body"],
            "permalink": found["permalink"],
        },
    ).fetchone()
    return row[0] if row else None


def attach(conn, case_id, found, added_by):
    row = conn.execute(
        ATTACH,
        {
            "case_id": case_id,
            "channel_id": found["channel_id"],
            "thread_ts": found["thread_ts"],
            "added_by": added_by,
        },
    ).fetchone()
    if row is None:
        return None

    thread_id, primary = row
    audit.record(
        conn,
        "thread",
        thread_id,
        "attached",
        added_by,
        after={
            "case_id": case_id,
            "channel_id": found["channel_id"],
            "thread_ts": found["thread_ts"],
            "kind": "evidence",
            "is_primary": primary,
            "came_with_the_report": True,
        },
    )
    return thread_id


def promote(conn, case_id, conversation_id, added_by):
    threads, messages = 0, 0

    for found in shared(conn, conversation_id):
        if attach(conn, case_id, found, added_by) is not None:
            threads += 1
        if keep(conn, found) is not None:
            messages += 1

    return {"threads": threads, "messages": messages}
