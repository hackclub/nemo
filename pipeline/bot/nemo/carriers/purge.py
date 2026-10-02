import json
import logging

from bot.core import session
from bot.nemo import guardwork

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


class Ceiling(RuntimeError):
    """More messages hang off these than a purge is allowed to take down"""


def waiting(conn):
    return conn.execute(WAITING).fetchall()


def claim(conn, purge_id):
    return conn.execute(CLAIM, (purge_id,)).fetchone()


def worth_taking(said):
    return said.get("subtype") != "channel_join" and said.get("ts")


def has_replies(said):
    if said.get("reply_count"):
        return True
    return bool(said.get("thread_ts")) and said.get("thread_ts") == said.get("ts")


def newest(client, channel_id, wanted):
    held = []
    cursor = None
    while len(held) < wanted:
        asked = {"channel": channel_id, "limit": min(PAGE, wanted - len(held))}
        if cursor:
            asked["cursor"] = cursor
        found = client.conversations_history(**asked) or {}
        for said in found.get("messages") or []:
            if not worth_taking(said):
                continue
            held.append(said)
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
        for said in found.get("messages") or []:
            if said.get("ts") and said["ts"] != thread_ts:
                seen.append(said)
        cursor = ((found.get("response_metadata") or {}).get("next_cursor") or "").strip()
        if not cursor:
            return seen


def kept_from(said, thread_ts=None):
    return {
        "ts": said.get("ts"),
        "thread_ts": thread_ts,
        "user": said.get("user") or said.get("bot_id"),
        "text": said.get("text"),
    }


def take_thread(client, channel_id, parent, taken):
    thread_ts = parent["ts"]
    for _ in range(MAX_PASSES):
        below = replies(client, channel_id, thread_ts)
        if not below:
            break
        for said in below:
            if len(taken) >= CEILING:
                raise Ceiling(f"more than {CEILING} messages hang off {channel_id}")
            guardwork.remove(client, channel_id, said["ts"])
            taken.append(kept_from(said, thread_ts))


def take(client, channel_id, said, taken):
    if has_replies(said):
        take_thread(client, channel_id, said, taken)
    if len(taken) >= CEILING:
        raise Ceiling(f"more than {CEILING} messages hang off {channel_id}")
    guardwork.remove(client, channel_id, said["ts"])
    taken.append(kept_from(said))


def run(client, purge_id):
    with session() as conn:
        claimed = claim(conn, purge_id)
    if claimed is None:
        return 0

    channel_id, wanted = claimed
    taken = []
    failure = None
    try:
        for said in newest(client, channel_id, min(wanted, MOST)):
            take(client, channel_id, said, taken)
    except Exception as blew_up:
        failure = str(blew_up)[:500]
        log.warning("nemo: purge %s stopped after %s: %s", purge_id, len(taken), failure)

    with session() as conn:
        conn.execute(FAILED if failure else DONE,
                     (len(taken), json.dumps(taken), failure, purge_id) if failure
                     else (len(taken), json.dumps(taken), purge_id))

    log.info("nemo: purge %s took down %s in %s", purge_id, len(taken), channel_id)
    return len(taken)
