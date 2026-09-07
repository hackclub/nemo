import logging
import os
import threading

from slack_sdk.errors import SlackApiError

from bot.engine.db import session

log = logging.getLogger("bot.spine")

DEFAULT_SECONDS = 3600
PAGE_SIZE = 1000
HELD_KINDS = "public_channel,private_channel"

NEVER_JOINABLE = frozenset({
    "is_archived",
    "channel_not_found",
    "channel_is_limited_access",
    "no_permission",
    "too_many_members",
    "method_not_supported_for_channel_type",
})

FORGET_MEMBERSHIP = "UPDATE raw.channel_dim SET is_member = false WHERE is_member"

RECORD_MEMBERSHIP = """
UPDATE raw.channel_dim
SET is_member = true, membership_seen_at = now(), join_blocked_at = NULL, join_error = NULL,
    updated_at = now()
WHERE channel_id = ANY(%s)
"""

JOINABLE = """
SELECT channel_id
FROM raw.channel_dim
WHERE archived IS NOT TRUE AND is_member IS FALSE AND join_blocked_at IS NULL
ORDER BY channel_id
"""

BLOCK = """
UPDATE raw.channel_dim
SET join_blocked_at = now(), join_error = %s, updated_at = now()
WHERE channel_id = %s
"""


def every():
    return int(os.environ.get("SPINE_JOIN_SECONDS", "") or DEFAULT_SECONDS)


def mine(client):
    seen, cursor = [], None
    while True:
        answer = client.users_conversations(
            types=HELD_KINDS, exclude_archived=True, limit=PAGE_SIZE, cursor=cursor
        )
        seen.extend(c["id"] for c in answer.get("channels") or [])
        cursor = (answer.get("response_metadata") or {}).get("next_cursor")
        if not cursor:
            return seen


def refresh(client):
    held = mine(client)
    with session() as conn:
        conn.execute(FORGET_MEMBERSHIP)
        if held:
            conn.execute(RECORD_MEMBERSHIP, (held,))
    return len(held)


def joinable():
    with session() as conn:
        return [row[0] for row in conn.execute(JOINABLE).fetchall()]


def block(channel_id, reason):
    with session() as conn:
        conn.execute(BLOCK, (reason, channel_id))


def join(client, channel_id):
    try:
        client.conversations_join(channel=channel_id)
        return True
    except SlackApiError as refusal:
        reason = (refusal.response or {}).get("error") or str(refusal)
        if reason in NEVER_JOINABLE:
            block(channel_id, reason)
            return False
        raise


def once(client):
    held = refresh(client)
    wanted = joinable()
    joined, blocked = 0, 0
    for channel_id in wanted:
        try:
            if join(client, channel_id):
                joined += 1
            else:
                blocked += 1
        except Exception as failure:
            log.warning("spine: could not join %s, trying again next cycle: %s",
                        channel_id, failure)
            break
    if joined:
        refresh(client)
    return held, joined, blocked


def start(client, stopping):
    seconds = every()

    def loop():
        log.info("spine: keeping the bot joined, every %ss", seconds)
        while True:
            try:
                held, joined, blocked = once(client)
                if joined or blocked:
                    log.info("spine: in %d channel(s), joined %d, %d cannot be joined",
                             held, joined, blocked)
            except Exception:
                log.exception("spine: the join pass failed, trying again next time")
            if stopping.wait(seconds):
                return

    thread = threading.Thread(target=loop, name="spine-join", daemon=True)
    thread.start()
    return thread
