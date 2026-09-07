import logging
import os
import threading

from slack_sdk.errors import SlackApiError

from bot.engine.db import session

log = logging.getLogger("bot.spine")

DEFAULT_SECONDS = 3600
PAGE_SIZE = 1000
HELD_KINDS = "public_channel,private_channel"

DEFAULT_PACE = 1.05
THROTTLED = "ratelimited"
BACKSTOP_WAIT = 60
GIVE_UP_AFTER = 3
TRUTHY = frozenset({"1", "true", "yes", "on"})

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


def joining():
    return os.environ.get("SPINE_JOIN_ENABLED", "").strip().lower() in TRUTHY


def every():
    return int(os.environ.get("SPINE_JOIN_SECONDS", "") or DEFAULT_SECONDS)


def pace():
    return float(os.environ.get("SPINE_JOIN_PACE", "") or DEFAULT_PACE)


def most():
    return int(os.environ.get("SPINE_JOIN_LIMIT", "") or 0)


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


def held_off(refusal):
    headers = getattr(refusal.response, "headers", None) or {}
    for name, value in headers.items():
        if str(name).lower() == "retry-after":
            try:
                return max(int(str(value).strip()), 1)
            except (TypeError, ValueError):
                break
    return BACKSTOP_WAIT


def join(client, channel_id, stopping):
    while True:
        try:
            client.conversations_join(channel=channel_id)
            return True
        except SlackApiError as refusal:
            reason = (refusal.response or {}).get("error") or str(refusal)
            if reason in NEVER_JOINABLE:
                block(channel_id, reason)
                return False
            if reason != THROTTLED:
                raise
            waiting = held_off(refusal)
            log.info("spine: rate limited, holding %ss then carrying on", waiting)
            if stopping.wait(waiting):
                return False


def once(client, stopping):
    held = refresh(client)
    if not joining():
        return held, 0, 0

    wanted = joinable()
    cap = most()
    if cap:
        wanted = wanted[:cap]

    gap = pace()
    joined, blocked, failing = 0, 0, 0
    for channel_id in wanted:
        if stopping.is_set():
            break
        try:
            if join(client, channel_id, stopping):
                joined += 1
            else:
                blocked += 1
            failing = 0
        except Exception as failure:
            failing += 1
            log.warning("spine: could not join %s: %s", channel_id, failure)
            if failing >= GIVE_UP_AFTER:
                log.warning("spine: giving up this pass, %d join(s) failed in a row", failing)
                break
        if stopping.wait(gap):
            break
    if joined:
        refresh(client)
    return held, joined, blocked


def start(client, stopping):
    seconds = every()

    def loop():
        if joining():
            log.info("spine: keeping the bot joined, every %ss, %.2fs between joins",
                     seconds, pace())
        else:
            log.info("spine: joining is off, only tracking membership every %ss", seconds)
        while True:
            try:
                held, joined, blocked = once(client, stopping)
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
