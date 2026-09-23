import logging
import threading

from bot.core import audit, blobs

log = logging.getLogger("bot.nemo")

LOCK = "lock"
DESTROY = "destroy"

MAX_PASSES = 12
PAGE = 200

WARNING = {
    DESTROY: ":rotating_light: *This thread is being destroyed.* "
             "Posting here now signs you out of Slack on every device.",
    LOCK: ":lock: *This thread is locked.* Replies are removed. "
          "Keep posting and you are signed out of Slack on every device.",
}

OPEN = """
INSERT INTO fd.thread_guards (kind, channel_id, thread_ts, opened_by, reason, expires_at, case_id)
VALUES (%s, %s, %s, %s, %s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING id
"""

HELD = """
SELECT id, kind, channel_id, thread_ts, state, opened_by, warned_ts, expires_at
FROM fd.thread_guards
WHERE channel_id = %s AND thread_ts = %s AND state IN ('warned', 'running')
"""

BY_ID = """
SELECT id, kind, channel_id, thread_ts, state, opened_by, warned_ts, expires_at
FROM fd.thread_guards WHERE id = %s
"""

LIVE = """
SELECT channel_id, thread_ts FROM fd.thread_guards WHERE state IN ('warned', 'running')
"""

WARNED = """
UPDATE fd.thread_guards SET warned_ts = %s, warned_at = now(), updated_at = now()
WHERE id = %s AND warned_ts IS NULL
"""

RUNNING = """
UPDATE fd.thread_guards SET state = 'running', started_at = now(), updated_at = now()
WHERE id = %s AND state = 'warned'
RETURNING id
"""

PROGRESS = """
UPDATE fd.thread_guards
SET passes = passes + 1, deleted_count = deleted_count + %s, updated_at = now()
WHERE id = %s
"""

FINISHED = """
UPDATE fd.thread_guards
SET state = %s, finished_at = now(), error = %s, transcript_sha = coalesce(%s, transcript_sha),
    updated_at = now()
WHERE id = %s
"""

PENDING = """
SELECT id FROM fd.thread_guards
WHERE kind = 'destroy' AND state IN ('warned', 'running')
ORDER BY created_at LIMIT 5
"""

LIFTING = """
SELECT id FROM fd.thread_guards
WHERE kind = 'lock' AND state IN ('warned', 'running') AND expires_at <= now()
ORDER BY expires_at LIMIT 20
"""

KEPT = """
INSERT INTO fd.thread_guard_messages (guard_id, message_ts, user_id, channel_id)
VALUES (%s, %s, %s, %s)
ON CONFLICT (guard_id, message_ts) DO NOTHING
RETURNING message_ts
"""

REMOVED = """
UPDATE fd.thread_guard_messages SET removed_at = now()
WHERE guard_id = %s AND message_ts = %s AND removed_at IS NULL
"""

STILL_UP = """
SELECT m.guard_id, m.channel_id, m.message_ts
FROM fd.thread_guard_messages m
JOIN fd.thread_guards g ON g.id = m.guard_id
WHERE m.removed_at IS NULL
ORDER BY m.at
LIMIT %s
"""

OVER_THE_LINE = """
SELECT m.guard_id, m.user_id, count(*)::integer, g.channel_id, g.thread_ts
FROM fd.thread_guard_messages m
JOIN fd.thread_guards g ON g.id = m.guard_id
LEFT JOIN fd.thread_guard_strikes s
    ON s.guard_id = m.guard_id AND s.user_id = m.user_id
WHERE s.reset_at IS NULL OR s.reset_outcome LIKE 'failed:%%'
GROUP BY m.guard_id, m.user_id, g.channel_id, g.thread_ts
HAVING count(*) >= %s
ORDER BY m.guard_id, m.user_id
LIMIT 50
"""

CLAIM_RESET = """
INSERT INTO fd.thread_guard_strikes (guard_id, user_id, messages, reset_at, reset_outcome)
VALUES (%s, %s, %s, now(), 'claimed')
ON CONFLICT (guard_id, user_id) DO UPDATE
SET messages = EXCLUDED.messages, reset_at = now(), reset_outcome = 'claimed',
    last_at = now()
WHERE fd.thread_guard_strikes.reset_at IS NULL
   OR fd.thread_guard_strikes.reset_outcome LIKE 'failed:%%'
RETURNING user_id
"""

RESET_DONE = """
UPDATE fd.thread_guard_strikes SET reset_outcome = %s
WHERE guard_id = %s AND user_id = %s
"""

RESET_COUNT = """
SELECT count(*) FROM fd.thread_guard_strikes
WHERE guard_id = %s AND reset_at IS NOT NULL AND reset_outcome IN ('reset', 'would')
"""

STANDING = """
SELECT coalesce(bool_or(m.is_bot OR m.is_admin OR m.is_owner), false)
FROM fd.member m WHERE m.user_id = %s
"""

FD = "SELECT app.holds_capability(%s, 'case.read')"

_watched = set()
_loaded = False
_guard = threading.Lock()


def refresh(conn):
    global _loaded
    rows = {(row[0], row[1]) for row in conn.execute(LIVE).fetchall()}
    with _guard:
        _watched.clear()
        _watched.update(rows)
        _loaded = True
    return len(rows)


def watching(channel_id, thread_ts):
    with _guard:
        if not _loaded:
            return True
        return (channel_id, thread_ts) in _watched


def held(conn, channel_id, thread_ts):
    return conn.execute(HELD, (channel_id, thread_ts)).fetchone()


def by_id(conn, guard_id):
    return conn.execute(BY_ID, (guard_id,)).fetchone()


def open_guard(conn, kind, channel_id, thread_ts, by, reason, expires_at=None, case_id=None):
    row = conn.execute(
        OPEN, (kind, channel_id, thread_ts, by, reason, expires_at, case_id)
    ).fetchone()
    if row is None:
        return None

    guard_id = row[0]
    audit.record(
        conn, "thread_guard", guard_id, "opened", by,
        after={"kind": kind, "channel_id": channel_id, "thread_ts": thread_ts,
               "reason": reason, "expires_at": str(expires_at) if expires_at else None},
    )
    return guard_id


def warn(client, conn, guard_id, channel_id, thread_ts, kind):
    sent = client.chat_postMessage(
        channel=channel_id, thread_ts=thread_ts, text=WARNING[kind], unfurl_links=False
    )
    conn.execute(WARNED, (sent["ts"], guard_id))
    return sent["ts"]


def exempt(conn, user_id, opened_by):
    if not user_id or user_id == opened_by:
        return True
    if conn.execute(STANDING, (user_id,)).fetchone()[0]:
        return True
    return bool(conn.execute(FD, (user_id,)).fetchone()[0])


def kept(conn, guard_id, channel_id, user_id, message_ts):
    conn.execute(KEPT, (guard_id, message_ts, user_id, channel_id))


def removed(conn, guard_id, message_ts):
    conn.execute(REMOVED, (guard_id, message_ts))


def still_up(conn, limit):
    return conn.execute(STILL_UP, (limit,)).fetchall()


def over_the_line(conn, needed):
    return conn.execute(OVER_THE_LINE, (needed,)).fetchall()


def punished(conn, guard_id):
    return conn.execute(RESET_COUNT, (guard_id,)).fetchone()[0]


def claim_reset(conn, guard_id, user_id, messages):
    return conn.execute(CLAIM_RESET, (guard_id, user_id, messages)).fetchone() is not None


def reset_done(conn, guard_id, user_id, outcome, channel_id, thread_ts, messages):
    conn.execute(RESET_DONE, (outcome, guard_id, user_id))
    audit.record(
        conn, "member", 0, "session_reset", user_id, actor_kind="system",
        after={"user_id": user_id, "guard_id": guard_id, "outcome": outcome,
               "messages": messages, "channel_id": channel_id, "thread_ts": thread_ts},
    )


def transcript(client, channel_id, thread_ts):
    seen, cursor = [], None
    while True:
        answer = client.conversations_replies(
            channel=channel_id, ts=thread_ts, limit=PAGE, cursor=cursor
        )
        for one in answer.get("messages") or []:
            if one.get("ts"):
                seen.append(one)
        cursor = (answer.get("response_metadata") or {}).get("next_cursor")
        if not cursor:
            return seen


def keep_transcript(conn, said):
    lines = [
        f"{one.get('ts')}\t{one.get('user') or one.get('bot_id') or 'unknown'}\t"
        f"{(one.get('text') or '').replace(chr(10), ' ')}"
        for one in sorted(said, key=lambda one: float(one.get("ts") or 0))
    ]
    body = ("\n".join(lines) + "\n").encode("utf-8")
    return blobs.stash(conn, body, "text/plain")


def pending(conn):
    return [row[0] for row in conn.execute(PENDING).fetchall()]


def lifting(conn):
    return [row[0] for row in conn.execute(LIFTING).fetchall()]


def start(conn, guard_id):
    return conn.execute(RUNNING, (guard_id,)).fetchone() is not None


def progressed(conn, guard_id, deleted):
    conn.execute(PROGRESS, (deleted, guard_id))


def finish(conn, guard_id, state, error=None, sha=None):
    conn.execute(FINISHED, (state, error, sha, guard_id))
    audit.record(
        conn, "thread_guard", guard_id, "lifted", "system", actor_kind="system",
        after={"state": state, "error": error},
    )
