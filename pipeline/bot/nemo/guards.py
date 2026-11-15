import datetime as dt
import json
import logging
import threading

from bot.core import audit
from bot.nemo import exemptions

log = logging.getLogger("bot.nemo")

LOCK = "lock"
DESTROY = "destroy"

MAX_PASSES = 12
PAGE = 200

WARNING = {
    DESTROY: "*This thread is being deleted.* "
             "Posting here signs you out of Slack on every device.",
    LOCK: "*This thread is locked.* New replies are deleted. "
          "Repeated replies sign you out of Slack on every device.",
}

OPEN = """
INSERT INTO fd.thread_guards (kind, channel_id, thread_ts, opened_by, reason, expires_at, case_id)
VALUES (%s, %s, %s, %s, %s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING id
"""

ACTIVE_ON_THREAD = """
SELECT id, kind, channel_id, thread_ts, state, opened_by, warned_ts, expires_at
FROM fd.thread_guards
WHERE channel_id = %s AND thread_ts = %s AND state IN ('warned', 'running')
  AND (expires_at IS NULL OR expires_at > now())
"""

LIVE_ON_THREAD = """
SELECT id, kind, opened_by, expires_at, reason, warned_ts
FROM fd.thread_guards
WHERE channel_id = %s AND thread_ts = %s AND state IN ('warned', 'running')
"""

EXTENDED = """
UPDATE fd.thread_guards SET expires_at = %s, updated_at = now()
WHERE id = %s AND kind = 'lock' AND state IN ('warned', 'running')
RETURNING id
"""

LOCK_REACTION = "lock"

LOCK_NOTICE = """
SELECT channel_id, warned_ts, expires_at, reason FROM fd.thread_guards
WHERE id = %s AND kind = 'lock' AND state IN ('warned', 'running') AND warned_ts IS NOT NULL
"""

WARNINGS_TO_REMOVE = """
SELECT id, channel_id, thread_ts, warned_ts FROM fd.thread_guards
WHERE kind = 'lock' AND state IN ('done', 'failed') AND warned_ts IS NOT NULL
  AND warning_removed_at IS NULL
ORDER BY finished_at
LIMIT %s
"""

WARNING_REMOVED = "UPDATE fd.thread_guards SET warning_removed_at = now() WHERE id = %s"

BY_ID = """
SELECT id, kind, channel_id, thread_ts, state, opened_by, warned_ts, expires_at
FROM fd.thread_guards WHERE id = %s
"""

LIVE = """
SELECT channel_id, thread_ts FROM fd.thread_guards WHERE state IN ('warned', 'running')
"""

SET_NOTE = """
UPDATE fd.thread_guards SET note_rich = %s, note_text = %s, updated_at = now()
WHERE id = %s
"""

NOTE_FOR = """
SELECT note_rich, note_text, note_ts FROM fd.thread_guards WHERE id = %s
"""

NOTE_POSTED = """
UPDATE fd.thread_guards
SET note_ts = %s, note_posted_at = now(), updated_at = now()
WHERE id = %s
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

ON_A_CASE = """
SELECT case_id FROM fd.case_threads
WHERE channel_id = %s AND thread_ts = %s AND removed_at IS NULL
ORDER BY is_primary DESC, added_at LIMIT 1
"""

PENDING_DESTROYS = """
SELECT id FROM fd.thread_guards
WHERE kind = 'destroy' AND state IN ('warned', 'running')
ORDER BY created_at LIMIT 5
"""

EXPIRED_LOCKS = """
SELECT id FROM fd.thread_guards
WHERE kind = 'lock' AND state IN ('warned', 'running') AND expires_at <= now()
ORDER BY expires_at LIMIT 20
"""

INSERT_MESSAGE = """
INSERT INTO fd.thread_guard_messages (guard_id, message_ts, user_id, channel_id)
VALUES (%s, %s, %s, %s)
ON CONFLICT (guard_id, message_ts) DO NOTHING
RETURNING message_ts
"""

MARK_MESSAGE_REMOVED = """
UPDATE fd.thread_guard_messages SET removed_at = now()
WHERE guard_id = %s AND message_ts = %s AND removed_at IS NULL
"""

UNREMOVED_MESSAGES = """
SELECT m.guard_id, m.channel_id, m.message_ts
FROM fd.thread_guard_messages m
JOIN fd.thread_guards g ON g.id = m.guard_id
WHERE m.removed_at IS NULL
ORDER BY m.at
LIMIT %s
"""

MESSAGE_COUNT = """
SELECT count(*)::integer FROM fd.thread_guard_messages
WHERE guard_id = %s AND user_id = %s
"""

USERS_OVER_THRESHOLD = """
SELECT m.guard_id, m.user_id, count(*)::integer, g.channel_id, g.thread_ts
FROM fd.thread_guard_messages m
JOIN fd.thread_guards g ON g.id = m.guard_id
LEFT JOIN fd.thread_guard_strikes s
    ON s.guard_id = m.guard_id AND s.user_id = m.user_id
WHERE g.state IN ('warned', 'running')
  AND (s.reset_at IS NULL OR s.reset_outcome LIKE 'failed:%%')
  AND (%(cap)s = 0 OR (
      SELECT count(*) FROM fd.thread_guard_strikes r
      WHERE r.guard_id = m.guard_id AND r.reset_at IS NOT NULL AND r.reset_outcome IN ('reset', 'would')
  ) < %(cap)s)
GROUP BY m.guard_id, m.user_id, g.channel_id, g.thread_ts
HAVING count(*) >= %(needed)s
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

BOT_MEMBER = "SELECT coalesce(bool_or(m.is_bot), false) FROM fd.member m WHERE m.user_id = %s"

_watched = set()
_loaded = False
_lock = threading.Lock()


def refresh(conn):
    global _loaded
    rows = {(row[0], row[1]) for row in conn.execute(LIVE).fetchall()}
    with _lock:
        _watched.clear()
        _watched.update(rows)
        _loaded = True
    return len(rows)


def is_watched(channel_id, thread_ts):
    with _lock:
        if not _loaded:
            return True
        return (channel_id, thread_ts) in _watched


def has_live_guard(channel_id, thread_ts):
    with _lock:
        return _loaded and (channel_id, thread_ts) in _watched


def active_guard(conn, channel_id, thread_ts):
    return conn.execute(ACTIVE_ON_THREAD, (channel_id, thread_ts)).fetchone()


def by_id(conn, guard_id):
    return conn.execute(BY_ID, (guard_id,)).fetchone()


def live_on_thread(conn, channel_id, thread_ts):
    row = conn.execute(LIVE_ON_THREAD, (channel_id, thread_ts)).fetchone()
    if row is None:
        return None
    return dict(zip(("id", "kind", "opened_by", "expires_at", "reason", "warned_ts"), row))


def extend(conn, current, expires_at, by):
    row = conn.execute(EXTENDED, (expires_at, current["id"])).fetchone()
    if row is None:
        return None
    audit.record(conn, "thread_guard", current["id"], "extended", by,
                 before={"expires_at": str(current["expires_at"]) if current["expires_at"] else None},
                 after={"expires_at": str(expires_at) if expires_at else None})
    return row[0]


def warnings_to_remove(conn, limit):
    return conn.execute(WARNINGS_TO_REMOVE, (limit,)).fetchall()


def warning_removed(conn, guard_id):
    conn.execute(WARNING_REMOVED, (guard_id,))


def lock_notice_row(conn, guard_id):
    row = conn.execute(LOCK_NOTICE, (guard_id,)).fetchone()
    if row is None:
        return None
    return dict(zip(("channel_id", "warned_ts", "expires_at", "reason"), row))


def case_of(conn, channel_id, thread_ts):
    row = conn.execute(ON_A_CASE, (channel_id, thread_ts)).fetchone()
    return row[0] if row else None


def set_note(conn, guard_id, messages, text):
    conn.execute(SET_NOTE, (json.dumps(messages), text, guard_id))


def note_for(conn, guard_id):
    return conn.execute(NOTE_FOR, (guard_id,)).fetchone()


def note_posted(conn, guard_id, ts):
    conn.execute(NOTE_POSTED, (ts, guard_id))


def open_guard(conn, kind, channel_id, thread_ts, by, reason, expires_at=None, case_id=None):
    if case_id is None:
        case_id = case_of(conn, channel_id, thread_ts)

    row = conn.execute(
        OPEN, (kind, channel_id, thread_ts, by, reason, expires_at, case_id)
    ).fetchone()
    if row is None:
        return None

    guard_id = row[0]
    audit.record(
        conn, "thread_guard", guard_id, "opened", by,
        after={"kind": kind, "channel_id": channel_id, "thread_ts": thread_ts,
               "case_id": case_id, "reason": reason,
               "expires_at": str(expires_at) if expires_at else None},
    )
    return guard_id


def warn(client, conn, guard_id, channel_id, thread_ts, kind, notice=None):
    sent = client.chat_postMessage(
        channel=channel_id, thread_ts=thread_ts, unfurl_links=False, **(notice or {"text": WARNING[kind]})
    )
    conn.execute(WARNED, (sent["ts"], guard_id))
    if kind == LOCK:
        try:
            client.reactions_add(channel=channel_id, timestamp=thread_ts, name=LOCK_REACTION)
        except Exception as failure:
            log.info("nemo: guard %s could not mark the root of %s: %s", guard_id, thread_ts, failure)
    return sent["ts"]


def exempt(conn, user_id, opened_by):
    if not user_id or user_id == opened_by:
        return True
    if conn.execute(BOT_MEMBER, (user_id,)).fetchone()[0]:
        return True
    return exemptions.is_exempt(conn, user_id)


def record_message(conn, guard_id, channel_id, user_id, message_ts):
    conn.execute(INSERT_MESSAGE, (guard_id, message_ts, user_id, channel_id))


def mark_message_removed(conn, guard_id, message_ts):
    conn.execute(MARK_MESSAGE_REMOVED, (guard_id, message_ts))


def unremoved_messages(conn, limit):
    return conn.execute(UNREMOVED_MESSAGES, (limit,)).fetchall()


def message_count(conn, guard_id, user_id):
    return conn.execute(MESSAGE_COUNT, (guard_id, user_id)).fetchone()[0]


def users_over_threshold(conn, needed, cap):
    return conn.execute(USERS_OVER_THRESHOLD, {"needed": needed, "cap": cap}).fetchall()


def strike_count(conn, guard_id):
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
    messages, cursor = [], None
    while True:
        response = client.conversations_replies(
            channel=channel_id, ts=thread_ts, limit=PAGE, cursor=cursor
        )
        for one in response.get("messages") or []:
            if one.get("ts"):
                messages.append(one)
        cursor = (response.get("response_metadata") or {}).get("next_cursor")
        if not cursor:
            return messages


INSERT_TRANSCRIPT = """
INSERT INTO fd.thread_transcripts (guard_id, channel_id, thread_ts, body)
VALUES (%s, %s, %s, %s)
RETURNING id
"""


def format_timestamp(ts):
    try:
        when = dt.datetime.fromtimestamp(float(ts), dt.UTC)
    except (TypeError, ValueError):
        return str(ts)
    return when.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def author_label(one, names):
    user_id = one.get("user") or one.get("bot_id") or "unknown"
    name = names.get(user_id) or one.get("username") or user_id
    return f"{user_id}|{name}"


def transcript_line(one, names):
    words = (one.get("text") or "").replace(chr(10), " ")
    return f"[{format_timestamp(one.get('ts'))}] <{author_label(one, names)}> {words}"


def transcript_body(messages, names):
    lines = [
        transcript_line(one, names)
        for one in sorted(messages, key=lambda one: float(one.get("ts") or 0))
    ]
    return "\n".join(lines) + "\n"


def store_transcript(conn, guard_id, channel_id, thread_ts, messages, names=None):
    body = transcript_body(messages, names or {})
    conn.execute(INSERT_TRANSCRIPT, (guard_id, channel_id, thread_ts, body))
    return body


def pending_destroys(conn):
    return [row[0] for row in conn.execute(PENDING_DESTROYS).fetchall()]


def expired_locks(conn):
    return [row[0] for row in conn.execute(EXPIRED_LOCKS).fetchall()]


def start(conn, guard_id):
    return conn.execute(RUNNING, (guard_id,)).fetchone() is not None


def add_progress(conn, guard_id, deleted):
    conn.execute(PROGRESS, (deleted, guard_id))


def finish(conn, guard_id, state, error=None, sha=None, by=None):
    conn.execute(FINISHED, (state, error, sha, guard_id))
    audit.record(
        conn, "thread_guard", guard_id, "lifted", by or "system",
        actor_kind="human" if by else "system",
        after={"state": state, "error": error},
    )
