import json
import logging

from bot.core import session
from bot.nemo import guard_actions

log = logging.getLogger("bot.nemo")

MOST = 100
CEILING = 500
PAGE = 200
MAX_PASSES = 12

WAITING = """
SELECT id, channel_id, wanted, asked_by
FROM fd.channel_purges
WHERE state = 'asked'
ORDER BY asked_at
LIMIT 20
"""

CLAIM = """
UPDATE fd.channel_purges
SET state = 'running', started_at = now()
WHERE id = %s AND state = 'asked'
RETURNING channel_id, wanted
"""

DONE = """
UPDATE fd.channel_purges
SET state = 'done', finished_at = now(), taken_down = %s, transcript = %s
WHERE id = %s AND state = 'running'
"""

FAILED = """
UPDATE fd.channel_purges
SET state = 'failed', finished_at = now(), taken_down = %s, transcript = %s, error = %s
WHERE id = %s AND state = 'running'
"""


class PurgeLimitExceeded(RuntimeError):
    """Raised when a thread exceeds the maximum messages a purge may delete."""


def waiting(conn):
    return conn.execute(WAITING).fetchall()


def claim(conn, purge_id):
    return conn.execute(CLAIM, (purge_id,)).fetchone()


def deletable(message):
    return message.get("subtype") != "channel_join" and message.get("ts")


def has_replies(message):
    if message.get("reply_count"):
        return True
    return bool(message.get("thread_ts")) and message.get("thread_ts") == message.get("ts")


def newest(client, channel_id, wanted):
    held = []
    cursor = None
    while len(held) < wanted:
        asked = {"channel": channel_id, "limit": min(PAGE, wanted - len(held))}
        if cursor:
            asked["cursor"] = cursor
        found = client.conversations_history(**asked) or {}
        for message in found.get("messages") or []:
            if not deletable(message):
                continue
            held.append(message)
            if len(held) >= wanted:
                break
        cursor = ((found.get("response_metadata") or {}).get("next_cursor") or "").strip()
        if not cursor:
            break
    return held


def replies(client, channel_id, thread_ts):
    seen, cursor = [], None
    while True:
        found = client.conversations_replies(
            channel=channel_id, ts=thread_ts, limit=PAGE, cursor=cursor
        ) or {}
        for message in found.get("messages") or []:
            if message.get("ts") and message["ts"] != thread_ts:
                seen.append(message)
        cursor = ((found.get("response_metadata") or {}).get("next_cursor") or "").strip()
        if not cursor:
            return seen


def kept_from(message, thread_ts=None):
    return {
        "ts": message.get("ts"),
        "thread_ts": thread_ts,
        "user": message.get("user") or message.get("bot_id"),
        "text": message.get("text"),
    }


def take_thread(client, channel_id, parent, taken):
    thread_ts = parent["ts"]
    for _ in range(MAX_PASSES):
        below = replies(client, channel_id, thread_ts)
        if not below:
            break
        for message in below:
            if len(taken) >= CEILING:
                raise PurgeLimitExceeded(f"more than {CEILING} messages hang off {channel_id}")
            guard_actions.remove(client, channel_id, message["ts"])
            taken.append(kept_from(message, thread_ts))


def delete_messages(client, channel_id, message, taken):
    if has_replies(message):
        take_thread(client, channel_id, message, taken)
    if len(taken) >= CEILING:
        raise PurgeLimitExceeded(f"more than {CEILING} messages hang off {channel_id}")
    guard_actions.remove(client, channel_id, message["ts"])
    taken.append(kept_from(message))


def run(client, purge_id):
    with session() as conn:
        claimed = claim(conn, purge_id)
    if claimed is None:
        return 0

    channel_id, wanted = claimed
    taken = []
    failure = None
    try:
        for message in newest(client, channel_id, min(wanted, MOST)):
            delete_messages(client, channel_id, message, taken)
    except Exception as blew_up:
        failure = str(blew_up)[:500]
        log.warning("nemo: purge %s stopped after %s: %s", purge_id, len(taken), failure)

    with session() as conn:
        conn.execute(FAILED if failure else DONE,
                     (len(taken), json.dumps(taken), failure, purge_id) if failure
                     else (len(taken), json.dumps(taken), purge_id))

    log.info("nemo: purge %s took down %s in %s", purge_id, len(taken), channel_id)
    return len(taken)
