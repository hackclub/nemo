from bot.engine import audit

FORWARDS = """
SELECT s.source_channel_id,
       coalesce(s.source_thread_ts, s.source_ts) AS thread_ts,
       s.source_ts
FROM fd.intake_shares s
JOIN fd.intake_messages m ON m.id = s.message_id
WHERE m.conversation_id = %s
  AND m.direction = 'inbound'
  AND s.kind = 'forward'
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


def forwards(conn, conversation_id):
    return [
        {"channel_id": row[0], "thread_ts": row[1], "source_ts": row[2]}
        for row in conn.execute(FORWARDS, (conversation_id,)).fetchall()
    ]


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
    return [
        thread_id
        for found in forwards(conn, conversation_id)
        if (thread_id := attach(conn, case_id, found, added_by)) is not None
    ]
