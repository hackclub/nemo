import argparse
import re
from datetime import datetime, timezone

from dotenv import load_dotenv

from lib import work
from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.task import per_entity

SOURCE = "conversations_history"
METHOD = "conversations.history"
PAGE_SIZE = 999
LOOKBACK_SECONDS = 7 * 86400
TRANSPORT = "history"
SUBSTANTIVE_CHARS = 80

MENTION = re.compile(r"<@([UW][A-Z0-9]+)")
EMOJI_ONLY = re.compile(r"(:[a-z0-9_+'-]+:\s*)+\Z")

MESSAGE_SQL = """
INSERT INTO raw.message
    (channel_id, ts, source, author_id, author_kind, subtype, thread_root_ts, is_reply,
     posted_at, edited_at, edited_by, reply_count, reply_users_count, latest_reply_ts,
     reaction_count, reactor_count, file_count, text_length, mention_count,
     is_question, is_substantive, has_link, emoji_only, mentioned_ids, observed_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (channel_id, ts) DO UPDATE SET
    author_id = EXCLUDED.author_id,
    author_kind = EXCLUDED.author_kind,
    subtype = EXCLUDED.subtype,
    thread_root_ts = EXCLUDED.thread_root_ts,
    is_reply = EXCLUDED.is_reply,
    edited_at = EXCLUDED.edited_at,
    edited_by = EXCLUDED.edited_by,
    reply_count = EXCLUDED.reply_count,
    reply_users_count = EXCLUDED.reply_users_count,
    latest_reply_ts = EXCLUDED.latest_reply_ts,
    reaction_count = EXCLUDED.reaction_count,
    reactor_count = EXCLUDED.reactor_count,
    file_count = EXCLUDED.file_count,
    text_length = EXCLUDED.text_length,
    mention_count = EXCLUDED.mention_count,
    is_question = EXCLUDED.is_question,
    is_substantive = EXCLUDED.is_substantive,
    has_link = EXCLUDED.has_link,
    emoji_only = EXCLUDED.emoji_only,
    mentioned_ids = EXCLUDED.mentioned_ids,
    observed_at = now()
"""

OBSERVATION_SQL = """
INSERT INTO raw.message_observation (channel_id, ts, transport)
VALUES (%s, %s, %s)
ON CONFLICT (channel_id, ts, transport) DO UPDATE SET observed_at = now()
"""

THREAD_SQL = """
INSERT INTO raw.thread
    (channel_id, root_ts, reply_count, reply_users_count, latest_reply_ts, seen_at)
VALUES (%s, %s, %s, %s, %s, now())
ON CONFLICT (channel_id, root_ts) DO UPDATE SET
    reply_count = EXCLUDED.reply_count,
    reply_users_count = EXCLUDED.reply_users_count,
    latest_reply_ts = EXCLUDED.latest_reply_ts,
    seen_at = now()
"""

WALK_SQL = """
INSERT INTO raw.channel_walk
    (channel_id, oldest_ts, newest_ts, messages_seen, history_complete, last_walked_at, updated_at)
VALUES (%s, %s, %s, %s, %s, now(), now())
ON CONFLICT (channel_id) DO UPDATE SET
    oldest_ts = least(raw.channel_walk.oldest_ts, EXCLUDED.oldest_ts),
    newest_ts = greatest(raw.channel_walk.newest_ts, EXCLUDED.newest_ts),
    messages_seen = raw.channel_walk.messages_seen + EXCLUDED.messages_seen,
    history_complete = raw.channel_walk.history_complete OR EXCLUDED.history_complete,
    last_walked_at = now(),
    last_error = NULL,
    updated_at = now()
"""

PRICE_SQL = """
UPDATE raw.channel_dim d SET
    thread_parents = t.parents,
    thread_replies = t.replies,
    threads_counted_at = now()
FROM (
    SELECT channel_id, count(*) AS parents, coalesce(sum(reply_count), 0) AS replies
    FROM raw.thread WHERE channel_id = ANY(%s) GROUP BY channel_id
) t
WHERE d.channel_id = t.channel_id
"""

TARGETS_SQL = """
SELECT d.channel_id, w.newest_ts
FROM raw.channel_dim d
LEFT JOIN raw.channel_walk w ON w.channel_id = d.channel_id
LEFT JOIN (
    SELECT first_post_channel AS channel_id, count(*) AS first_posts
    FROM raw.member_message_history
    WHERE first_post_channel IS NOT NULL
    GROUP BY first_post_channel
) f ON f.channel_id = d.channel_id
WHERE d.archived IS NOT TRUE
ORDER BY
    (w.last_walked_at IS NULL) DESC,
    coalesce(f.first_posts, 0) DESC,
    w.last_walked_at NULLS FIRST,
    d.channel_id
LIMIT %s
"""


def author_kind(message):
    if message.get("bot_id") or message.get("subtype") == "bot_message":
        return "bot"
    if message.get("user"):
        return "member"
    return "unknown"


def derived(text):
    stripped = (text or "").strip()
    return {
        "text_length": len(text or ""),
        "mentioned_ids": MENTION.findall(text or ""),
        "mention_count": len(MENTION.findall(text or "")),
        "is_question": "?" in (text or ""),
        "is_substantive": len(text or "") >= SUBSTANTIVE_CHARS,
        "has_link": "http" in (text or ""),
        "emoji_only": bool(stripped) and bool(EMOJI_ONLY.fullmatch(stripped)),
    }


def stamp(ts):
    return datetime.fromtimestamp(float(ts), tz=timezone.utc)


def message_row(channel_id, message):
    thread_root = message.get("thread_ts")
    edited = message.get("edited") or {}
    reactions = message.get("reactions") or []
    flags = derived(message.get("text"))
    return (
        channel_id,
        message["ts"],
        SOURCE,
        message.get("user") or message.get("bot_id"),
        author_kind(message),
        message.get("subtype"),
        thread_root,
        bool(thread_root) and thread_root != message["ts"],
        stamp(message["ts"]),
        stamp(edited["ts"]) if edited.get("ts") else None,
        edited.get("user"),
        message.get("reply_count"),
        message.get("reply_users_count"),
        message.get("latest_reply"),
        sum(r.get("count") or 0 for r in reactions),
        len({u for r in reactions for u in (r.get("users") or [])}),
        len(message.get("files") or []),
        flags["text_length"],
        flags["mention_count"],
        flags["is_question"],
        flags["is_substantive"],
        flags["has_link"],
        flags["emoji_only"],
        flags["mentioned_ids"],
    )


def thread_row(channel_id, message):
    if not message.get("reply_count"):
        return None
    return (
        channel_id,
        message["ts"],
        message.get("reply_count") or 0,
        message.get("reply_users_count") or 0,
        message.get("latest_reply"),
    )


def revisit_from(newest):
    try:
        return f"{max(float(newest) - LOOKBACK_SECONDS, 0):.6f}"
    except (TypeError, ValueError):
        return newest


def walk_params(channel_id, oldest=None, latest=None):
    params = {"channel": channel_id}
    if oldest:
        params["oldest"] = oldest
    if latest:
        params["latest"] = latest
        params["inclusive"] = False
    return params


def walk_channel(conn, client, channel_id, oldest=None, counts=None, latest=None, max_pages=None, on_page=None):
    params = walk_params(channel_id, oldest, latest)
    state = {"messages": [], "threads": [], "observations": [], "oldest_ts": None, "newest_ts": None, "pages": 0}
    seen = 0
    exhausted = True

    def checkpoint(done, page=True):
        with conn.cursor() as cur:
            if state["messages"]:
                cur.executemany(MESSAGE_SQL, state["messages"])
                cur.executemany(OBSERVATION_SQL, state["observations"])
            if state["threads"]:
                cur.executemany(THREAD_SQL, state["threads"])
            cur.execute(WALK_SQL, (
                channel_id, state["oldest_ts"], state["newest_ts"], len(state["messages"]), done))
        conn.commit()
        state["messages"], state["threads"], state["observations"] = [], [], []
        state["oldest_ts"] = state["newest_ts"] = None
        if page:
            state["pages"] += 1
            if on_page is not None:
                on_page(state["pages"])

    for message in client.paginate(
        METHOD, params, "messages",
        page_size=PAGE_SIZE, cursor_param="cursor", max_retries=8, credential="admin",
        page_param="limit", cursor_field="response_metadata.next_cursor",
        on_page=lambda cursor, total: checkpoint(False),
    ):
        if max_pages is not None and state["pages"] >= max_pages:
            exhausted = False
            break
        try:
            state["messages"].append(message_row(channel_id, message))
        except (KeyError, TypeError, ValueError) as exc:
            if counts:
                counts.rows_rejected += 1
            dead_letter(conn, SOURCE, {"channel": channel_id, "keys": sorted(message)}, str(exc))
            continue
        state["observations"].append((channel_id, message["ts"], TRANSPORT))
        thread = thread_row(channel_id, message)
        if thread:
            state["threads"].append(thread)
        seen += 1
        ts = message["ts"]
        state["oldest_ts"] = ts if state["oldest_ts"] is None or ts < state["oldest_ts"] else state["oldest_ts"]
        state["newest_ts"] = ts if state["newest_ts"] is None or ts > state["newest_ts"] else state["newest_ts"]

    checkpoint(exhausted and oldest is None, page=bool(state["messages"]))
    return seen, state["pages"], exhausted


BACKFILL_KIND = "channel_backfill"
TAIL_KIND = "channel_tail"
BACKFILL_PAGES = 10
TAIL_EVERY_SECONDS = 20 * 3600
LEASE_SECONDS = 1800

BACKFILL_SELECT = """
SELECT d.channel_id AS target_key, '' AS target_sub_key,
       1000 - least(coalesce(f.first_posts, 0), 999) AS priority,
       '{}'::jsonb AS payload, NULL::integer AS expected
FROM raw.channel_dim d
LEFT JOIN raw.channel_walk w ON w.channel_id = d.channel_id
LEFT JOIN (
    SELECT first_post_channel AS channel_id, count(*) AS first_posts
    FROM raw.member_message_history
    WHERE first_post_channel IS NOT NULL
    GROUP BY first_post_channel
) f ON f.channel_id = d.channel_id
WHERE d.archived IS NOT TRUE AND coalesce(w.history_complete, false) = false
"""

TAIL_SELECT = """
SELECT d.channel_id AS target_key, '' AS target_sub_key,
       CASE WHEN w.newest_ts IS NULL THEN 500 ELSE 100 END AS priority,
       '{}'::jsonb AS payload, NULL::integer AS expected
FROM raw.channel_dim d
LEFT JOIN raw.channel_walk w ON w.channel_id = d.channel_id
WHERE d.archived IS NOT TRUE
"""

CURSORS_SQL = "SELECT oldest_ts, newest_ts, history_complete FROM raw.channel_walk WHERE channel_id = %s"

ERROR_SQL = """
INSERT INTO raw.channel_walk (channel_id, last_error, updated_at)
VALUES (%s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET last_error = EXCLUDED.last_error, updated_at = now()
"""


def enqueue_backfill(conn, channels=None, priority=None):
    select = BACKFILL_SELECT
    params = ()
    if channels:
        select = select + " AND d.channel_id = ANY(%(p0)s)"
        params = (list(channels),)
    if priority is not None:
        select = select.replace("1000 - least(coalesce(f.first_posts, 0), 999) AS priority", f"{int(priority)} AS priority")
    queued = work.enqueue_select(conn, BACKFILL_KIND, select, params, requested_by=SOURCE)
    if channels and priority is not None:
        work.prioritize(conn, BACKFILL_KIND, channels, int(priority))
    return queued


def enqueue_tail(conn):
    return work.enqueue_select(conn, TAIL_KIND, TAIL_SELECT, requested_by=SOURCE,
                               requeue_settled_after=TAIL_EVERY_SECONDS)


def cursors(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(CURSORS_SQL, (channel_id,))
        row = cur.fetchone()
    return row if row else (None, None, False)


def remember_error(conn, channel_id, fault):
    with conn.cursor() as cur:
        cur.execute(ERROR_SQL, (channel_id, f"{fault.name}: {fault.detail[:380]}"))
    conn.commit()


def drain_tail(conn, client, counts, limit, targets=None):
    items = work.claim(conn, TAIL_KIND, limit, ttl_seconds=LEASE_SECONDS, targets=targets)
    messages = 0
    for item in items:
        channel_id = item.target_key
        _, newest, _ = cursors(conn, channel_id)

        def on_fault(fault, item=item, channel_id=channel_id):
            remember_error(conn, channel_id, fault)
            work.fail(conn, item, fault.detail)

        with per_entity(conn, SOURCE, counts, {"channel_id": channel_id, "kind": TAIL_KIND}, on_fault=on_fault):
            seen, pages, _ = walk_channel(conn, client, channel_id, oldest=revisit_from(newest) if newest else None,
                                          counts=counts, max_pages=None if newest else BACKFILL_PAGES)
            work.settle(conn, item, "complete", fetched=seen, note=f"{pages} page(s)")
            conn.commit()
            messages += seen
            counts.rows_in += seen
        counts.progress()
    return len(items), messages


def drain_backfill(conn, client, counts, limit, pages=BACKFILL_PAGES, targets=None):
    items = work.claim(conn, BACKFILL_KIND, limit, ttl_seconds=LEASE_SECONDS, targets=targets)
    messages, finished = 0, 0
    for item in items:
        channel_id = item.target_key
        oldest, _, complete = cursors(conn, channel_id)
        if complete:
            work.settle(conn, item, "complete", fetched=0, note="already complete")
            conn.commit()
            continue

        def on_fault(fault, item=item, channel_id=channel_id):
            remember_error(conn, channel_id, fault)
            work.fail(conn, item, fault.detail)

        def renew(page, item=item):
            work.renew(conn, item, LEASE_SECONDS)

        with per_entity(conn, SOURCE, counts, {"channel_id": channel_id, "kind": BACKFILL_KIND}, on_fault=on_fault):
            seen, walked_pages, exhausted = walk_channel(
                conn, client, channel_id, latest=oldest, counts=counts, max_pages=pages, on_page=renew)
            if exhausted:
                work.settle(conn, item, "complete", fetched=seen, note=f"{walked_pages} page(s), reached the start")
                finished += 1
            else:
                work.settle(conn, item, "short", fetched=seen, note=f"{walked_pages} page(s), more behind")
            conn.commit()
            if not exhausted:
                work.enqueue_select(conn, BACKFILL_KIND, BACKFILL_SELECT + " AND d.channel_id = %(p0)s",
                                    (channel_id,), requested_by=SOURCE, requeue_settled_after=0)
            messages += seen
            counts.rows_in += seen
        counts.progress()
    return len(items), messages, finished


def run(conn, limit=200, full=False, channels=None, backfill_limit=None):
    client = ProxyClient()
    work.reclaim(conn, TAIL_KIND)
    work.reclaim(conn, BACKFILL_KIND)
    if channels:
        queued_tail = 0
        queued_back = enqueue_backfill(conn, channels, priority=0)
    else:
        queued_tail = enqueue_tail(conn)
        queued_back = enqueue_backfill(conn)
    backfill_limit = max(1, limit // 4) if backfill_limit is None else backfill_limit
    if full:
        backfill_limit = limit

    with ingest_run(conn, SOURCE) as counts:
        tails, tail_messages = (0, 0) if channels else drain_tail(conn, client, counts, limit)
        backfills, back_messages, finished = drain_backfill(conn, client, counts, backfill_limit, targets=channels)
        touched = tails + backfills
        counts.total_expected = touched
        if touched:
            with conn.cursor() as cur:
                cur.execute(PRICE_SQL, ([c for c in (channels or []) ] or _touched_channels(conn),))
            conn.commit()

    print(f"{SOURCE}: {tails} tail walk(s), {tail_messages} messages; {backfills} backfill unit(s), "
          f"{back_messages} messages, {finished} channel(s) reached their start; "
          f"queued {queued_tail} tail, {queued_back} backfill; {counts.rows_rejected} failed")
    return counts.rows_in


def _touched_channels(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT target_key FROM ingest.work_item WHERE work_kind IN (%s, %s) "
                    "AND settled_at > now() - interval '1 hour'", (TAIL_KIND, BACKFILL_KIND))
        return [row[0] for row in cur.fetchall()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=200)
    parser.add_argument("--backfill-limit", type=int)
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--channel", action="append")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, limit=args.limit, full=args.full, channels=args.channel, backfill_limit=args.backfill_limit)


if __name__ == "__main__":
    main()
