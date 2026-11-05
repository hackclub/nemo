import logging
import time
from collections import namedtuple

from bot.core import access, audit, parse, privileged, session
from bot.nemo import channel, guard_actions

log = logging.getLogger("bot.nemo")

CAP = 10_000
PAGE = 200
BATCH = 200
SEARCH_COUNT = 100
SEARCH_PAGES = 100
MAX_PASSES = 12
CHECK_DELAY_SECONDS = 180
FAILURES_IN_A_ROW = 25
UNDELETABLE = frozenset({"channel_join", "channel_leave"})

QUEUED = "queued"
DELETED = "deleted"
ALREADY_DELETED = "gone"
FAILED = "failed"

Purge = namedtuple("Purge", "id channel_id member_id wanted asked_by")
Item = namedtuple("Item", "channel_id ts thread_ts author_id text reply_count")

QUEUED_PURGES = """
SELECT p.id
FROM fd.purges p
LEFT JOIN fd.member_guards g ON g.id = p.guard_id
WHERE p.state = 'asked'
  AND (p.guard_id IS NULL OR g.enforcement_status = 'held' OR g.state IN ('lifted', 'cancelled'))
ORDER BY p.asked_at
LIMIT 20
"""

GUARD_STATE = """
SELECT g.state, g.enforcement_status
FROM fd.purges p
JOIN fd.member_guards g ON g.id = p.guard_id
WHERE p.id = %s
"""

NO_GUARD = "none"
GUARD_ENFORCED = "held"
GUARD_PENDING = "pending"
GUARD_LIFTED = "lifted"
GUARD_CANCELLED = "cancelled"
DEACTIVATION_LIFTED = "Deactivation lifted"
DEACTIVATION_CANCELLED = "Deactivation cancelled"
GUARD_FAILURES = {GUARD_LIFTED: DEACTIVATION_LIFTED, GUARD_CANCELLED: DEACTIVATION_CANCELLED}

INTERRUPTED = """
UPDATE fd.purges
SET state = 'asked'
WHERE state IN ('running', 'checking')
RETURNING id
"""

CLAIM = """
UPDATE fd.purges
SET state = 'running', started_at = coalesce(started_at, now())
WHERE id = %s AND state = 'asked'
RETURNING id, channel_id, member_id, wanted, asked_by
"""

ITEM_COUNT = "SELECT count(*) FROM fd.purge_items WHERE purge_id = %s"

ENQUEUE_ITEMS = """
INSERT INTO fd.purge_items (purge_id, channel_id, ts, thread_ts, author_id, text, reply_count)
SELECT %s, new_item.channel_id, new_item.ts, new_item.thread_ts, new_item.author_id, new_item.text,
       new_item.reply_count
FROM unnest(%s::text[], %s::text[], %s::text[], %s::text[], %s::text[], %s::integer[])
    AS new_item(channel_id, ts, thread_ts, author_id, text, reply_count)
ON CONFLICT (purge_id, channel_id, ts) DO NOTHING
"""

SET_FOUND = "UPDATE fd.purges SET found = %s WHERE id = %s"

NEXT_ITEMS = f"""
SELECT channel_id, ts, thread_ts, author_id, text, reply_count
FROM fd.purge_items
WHERE purge_id = %s AND state = 'queued'
ORDER BY coalesce(thread_ts, ts) DESC, thread_ts IS NULL, ts DESC
LIMIT {BATCH}
"""

MARK_ITEM = """
UPDATE fd.purge_items
SET state = %s, error = %s, done_at = now()
WHERE purge_id = %s AND channel_id = %s AND ts = %s
"""

RECORD_ITEM = """
INSERT INTO fd.purge_items (purge_id, channel_id, ts, thread_ts, author_id, text, state, error,
                            done_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (purge_id, channel_id, ts) DO UPDATE
SET state = EXCLUDED.state, error = EXCLUDED.error, done_at = now()
"""

UPDATE_PROGRESS = """
UPDATE fd.purges
SET purged = (SELECT count(*) FROM fd.purge_items WHERE purge_id = %s AND state = 'deleted')
WHERE id = %s
"""

SET_CHECKING = "UPDATE fd.purges SET state = 'checking' WHERE id = %s AND state = 'running'"

DONE_ITEMS = "SELECT channel_id, ts, thread_ts FROM fd.purge_items WHERE purge_id = %s"

FINISH = """
UPDATE fd.purges
SET state = %s, finished_at = now(), error = %s, left_after_check = %s,
    checked_at = CASE WHEN %s THEN now() END,
    purged = (SELECT count(*) FROM fd.purge_items WHERE purge_id = %s AND state = 'deleted')
WHERE id = %s AND state IN ('running', 'checking')
RETURNING purged
"""

ARCHIVED_MESSAGES = """
SELECT channel_id, ts, CASE WHEN is_reply THEN thread_root_ts END
FROM archive.message
WHERE author_id = %(member_id)s
  AND deleted_at IS NULL
  AND (%(channel_id)s::text IS NULL OR channel_id = %(channel_id)s)
  AND coalesce(subtype, '') NOT IN ('channel_join', 'channel_leave')
ORDER BY posted_at DESC
LIMIT %(limit)s
"""


class PurgeLimitExceeded(RuntimeError):
    """Raised when a purge reaches the most messages one purge may delete."""


def queued_purges(conn):
    return conn.execute(QUEUED_PURGES).fetchall()


def requeue_interrupted(conn):
    return [row[0] for row in conn.execute(INTERRUPTED).fetchall()]


def guard_condition(conn, purge_id):
    row = conn.execute(GUARD_STATE, (purge_id,)).fetchone()
    if row is None:
        return NO_GUARD
    state, enforcement = row
    if state in (GUARD_LIFTED, GUARD_CANCELLED):
        return state
    return GUARD_ENFORCED if enforcement == "held" else GUARD_PENDING


def claim(conn, purge_id):
    row = conn.execute(CLAIM, (purge_id,)).fetchone()
    return Purge(*row) if row else None


def deletable(message):
    return bool(message.get("ts")) and message.get("subtype") not in UNDELETABLE


def has_replies(message):
    if message.get("reply_count"):
        return True
    return bool(message.get("thread_ts")) and message.get("thread_ts") == message.get("ts")


def next_cursor(page):
    return ((page or {}).get("response_metadata") or {}).get("next_cursor", "").strip() or None


def as_admin(client, channel_id, call):
    try:
        return call()
    except Exception as failure:
        if not privileged.channel_missing(failure) or not guard_actions.invite_admin(client, channel_id):
            raise
    return call()


def from_history(channel_id, message, thread_ts=None):
    return {
        "channel_id": channel_id,
        "ts": message["ts"],
        "thread_ts": thread_ts,
        "author_id": message.get("user") or message.get("bot_id"),
        "text": message.get("text"),
        "reply_count": (message.get("reply_count") or 1) if has_replies(message) else None,
    }


def channel_messages(client, purge):
    limit = min(purge.wanted or CAP, CAP)
    found, cursor = [], None
    while len(found) < limit:
        page = as_admin(client, purge.channel_id,
                        lambda at=cursor: privileged.history(purge.channel_id, cursor=at, limit=PAGE))
        for message in page.get("messages") or []:
            if deletable(message):
                found.append(from_history(purge.channel_id, message))
                if len(found) >= limit:
                    break
        cursor = next_cursor(page)
        if not cursor:
            break
    return found


def archived_messages(conn, purge, limit):
    rows = conn.execute(ARCHIVED_MESSAGES, {
        "member_id": purge.member_id, "channel_id": purge.channel_id, "limit": limit,
    }).fetchall()
    return [
        {"channel_id": channel_id, "ts": ts, "thread_ts": thread_ts,
         "author_id": purge.member_id, "text": None, "reply_count": None}
        for channel_id, ts, thread_ts in rows
    ]


def search_hit_item(purge, match):
    where = match.get("channel") or {}
    if where.get("is_im") or where.get("is_mpim") or match.get("user") != purge.member_id:
        return None
    if not where.get("id") or not match.get("ts"):
        return None
    if purge.channel_id and where["id"] != purge.channel_id:
        return None
    target = parse.link_target(match.get("permalink"))
    thread_ts = target[2] if target else None
    return {
        "channel_id": where["id"],
        "ts": match["ts"],
        "thread_ts": thread_ts if thread_ts != match["ts"] else None,
        "author_id": purge.member_id,
        "text": match.get("text"),
        "reply_count": None,
    }


def searched_messages(purge, limit):
    found = []
    for page_number in range(1, SEARCH_PAGES + 1):
        data = privileged.search(f"from:<@{purge.member_id}>", page=page_number, count=SEARCH_COUNT)
        results = data.get("messages") or {}
        found.extend(hit for hit in (search_hit_item(purge, match) for match in results.get("matches") or [])
                     if hit)
        if page_number >= ((results.get("paging") or {}).get("pages") or 0) or len(found) >= limit:
            break
    return found


def member_messages(purge):
    limit = min(purge.wanted or CAP, CAP)
    with session() as conn:
        found = {(one["channel_id"], one["ts"]): one for one in archived_messages(conn, purge, limit)}
    try:
        for one in searched_messages(purge, limit):
            found[(one["channel_id"], one["ts"])] = one
    except Exception as failure:
        log.warning("nemo: purge %s goes on from the archive alone, search failed: %s",
                    purge.id, failure)
    return sorted(found.values(), key=lambda one: float(one["ts"]), reverse=True)[:limit]


def collect(client, purge):
    return member_messages(purge) if purge.member_id else channel_messages(client, purge)


def enqueue_items(conn, purge_id, messages):
    if messages:
        conn.execute(ENQUEUE_ITEMS, (
            purge_id,
            [one["channel_id"] for one in messages],
            [one["ts"] for one in messages],
            [one["thread_ts"] for one in messages],
            [one["author_id"] for one in messages],
            [one["text"] for one in messages],
            [one["reply_count"] for one in messages],
        ))
    return len(messages)


def delete_one(client, channel_id, ts):
    try:
        guard_actions.remove(client, channel_id, ts)
        return DELETED, None
    except Exception as failure:
        if privileged.already_deleted(failure):
            return ALREADY_DELETED, None
        return FAILED, str(failure)[:300]


def record_item(purge_id, channel_id, message, thread_ts, state, error):
    with session() as conn:
        conn.execute(RECORD_ITEM, (purge_id, channel_id, message["ts"], thread_ts,
                             message.get("user") or message.get("bot_id"), message.get("text"),
                             state, error))


def item_count(purge_id):
    with session() as conn:
        return conn.execute(ITEM_COUNT, (purge_id,)).fetchone()[0]


def replies_of(client, channel_id, thread_ts):
    found, cursor = [], None
    while True:
        page = as_admin(client, channel_id,
                        lambda at=cursor: privileged.replies(channel_id, thread_ts, cursor=at, limit=PAGE))
        found.extend(message for message in page.get("messages") or []
                     if message.get("ts") and message["ts"] != thread_ts)
        cursor = next_cursor(page)
        if not cursor:
            return found


def sweep_thread(client, purge, parent):
    for _ in range(MAX_PASSES):
        thread_replies = replies_of(client, parent.channel_id, parent.ts)
        if not thread_replies:
            return
        for message in thread_replies:
            if item_count(purge.id) >= CAP:
                raise PurgeLimitExceeded(f"more than {CAP:,} messages")
            state, error = delete_one(client, parent.channel_id, message["ts"])
            record_item(purge.id, parent.channel_id, message, parent.ts, state, error)


def purge_queued(client, purge):
    in_a_row = 0
    while True:
        with session() as conn:
            batch = [Item(*row) for row in conn.execute(NEXT_ITEMS, (purge.id,)).fetchall()]
        if not batch:
            return
        for item in batch:
            if item.reply_count:
                sweep_thread(client, purge, item)
            state, error = delete_one(client, item.channel_id, item.ts)
            with session() as conn:
                conn.execute(MARK_ITEM, (state, error, purge.id, item.channel_id, item.ts))
            in_a_row = in_a_row + 1 if state == FAILED else 0
            if in_a_row >= FAILURES_IN_A_ROW:
                raise RuntimeError(f"{in_a_row} deletes failed in a row, last error: {error}")
        with session() as conn:
            conn.execute(UPDATE_PROGRESS, (purge.id, purge.id))


def channel_leftovers(client, purge, items):
    tops = sorted((ts for _, ts, thread_ts in items if thread_ts is None), key=float)
    if not tops:
        return []
    purged_ts = {ts for _, ts, _ in items}
    found, cursor = [], None
    while True:
        page = as_admin(client, purge.channel_id, lambda at=cursor: privileged.history(
            purge.channel_id, cursor=at, limit=PAGE, oldest=tops[0], latest=tops[-1]))
        found.extend(message for message in page.get("messages") or []
                     if deletable(message) and (not purge.wanted or message["ts"] in purged_ts))
        cursor = next_cursor(page)
        if not cursor:
            return found


def member_leftovers(purge, items):
    time.sleep(CHECK_DELAY_SECONDS)
    purged_pairs = {(channel_id, ts) for channel_id, ts, _ in items}
    return [one for one in searched_messages(purge, CAP)
            if not purge.wanted or (one["channel_id"], one["ts"]) in purged_pairs]


def check(client, purge):
    with session() as conn:
        conn.execute(SET_CHECKING, (purge.id,))
        items = conn.execute(DONE_ITEMS, (purge.id,)).fetchall()

    left = 0
    if purge.member_id:
        for one in member_leftovers(purge, items):
            state, error = delete_one(client, one["channel_id"], one["ts"])
            record_item(purge.id, one["channel_id"], {"ts": one["ts"], "user": purge.member_id,
                                                      "text": one["text"]}, one["thread_ts"], state, error)
            left += state == FAILED
        return left

    for message in channel_leftovers(client, purge, items):
        state, error = delete_one(client, purge.channel_id, message["ts"])
        record_item(purge.id, purge.channel_id, message, None, state, error)
        left += state == FAILED
    return left


def summary(purge, purged, left, failure, unchecked=None):
    from_member = f" from <@{purge.member_id}>" if purge.member_id else ""
    where = f"in <#{purge.channel_id}>" if purge.channel_id else "in every channel"
    text = (f"{purged} message{'' if purged == 1 else 's'}{from_member} deleted {where} "
            f"by <@{purge.asked_by}>")
    if failure:
        text += f", stopped: {failure}"
    elif unchecked:
        text += f", check failed: {unchecked}"
    elif left:
        text += f", {left} left after the check"
    text += "."
    url = (channel.app_url(f"/fd/channels/{purge.channel_id}/purges/{purge.id}") if purge.channel_id
           else channel.app_url(f"/fd/members/{purge.member_id}/purges/{purge.id}"))
    return f"{text}\n{url}" if url else text


def report(client, purge, purged, left, failure, unchecked=None):
    log_channel_id = channel.log_channel()
    if not log_channel_id:
        log.warning("nemo: no nemo.log_channel to post how purge %s went", purge.id)
        return
    try:
        client.chat_postMessage(channel=log_channel_id,
                                text=summary(purge, purged, left, failure, unchecked),
                                unfurl_links=False)
    except Exception as error:
        log.warning("nemo: could not post how purge %s went: %s", purge.id, error)


def still_allowed(conn, purge):
    allowed, _ = access.may(conn, purge.asked_by,
                            "member.purge" if purge.member_id else "channel.purge")
    return None if allowed else f"<@{purge.asked_by}> no longer has purge access"


def run(client, purge_id):
    with session() as conn:
        condition = guard_condition(conn, purge_id)
        if condition == GUARD_PENDING:
            return 0
        purge = claim(conn, purge_id)
        if purge is None:
            return 0
        resumed = conn.execute(ITEM_COUNT, (purge.id,)).fetchone()[0] > 0
        failure = GUARD_FAILURES.get(condition) or still_allowed(conn, purge)

    unchecked, left = None, None
    if failure is None:
        try:
            if not resumed:
                messages = collect(client, purge)
                with session() as conn:
                    conn.execute(SET_FOUND, (enqueue_items(conn, purge.id, messages), purge.id))
            purge_queued(client, purge)
        except Exception as error:
            failure = str(error)[:500]
            log.warning("nemo: purge %s stopped: %s", purge.id, failure)

    if failure is None:
        try:
            left = check(client, purge)
        except Exception as error:
            unchecked = str(error)[:500]
            log.warning("nemo: purge %s could not be checked: %s", purge.id, unchecked)

    error = failure or (f"check failed: {unchecked}" if unchecked else None)
    with session() as conn:
        row = conn.execute(FINISH, (FAILED if failure else "done", error, left,
                                    left is not None, purge.id, purge.id)).fetchone()
        purged = row[0] if row else 0
        audit.record(conn, "member_purge" if purge.member_id else "channel_purge", purge.id,
                     "performed", purge.asked_by, subject_user_id=purge.member_id,
                     after={"purged": purged, "left_after_check": left, "error": error})

    report(client, purge, purged, left, failure, unchecked)
    log.info("nemo: purge %s purged %s, %s left after the check", purge.id, purged, left)
    return purged
