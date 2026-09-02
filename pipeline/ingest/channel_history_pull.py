import argparse
import re
from datetime import datetime, timezone

from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient

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
WHERE d.archived IS NOT TRUE
ORDER BY w.last_walked_at NULLS FIRST, d.channel_id
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


def walk_channel(conn, client, channel_id, oldest=None, counts=None):
    params = {"channel": channel_id}
    if oldest:
        params["oldest"] = oldest

    messages, threads, observations = [], [], []
    seen = 0
    oldest_ts = newest_ts = None
    complete = oldest is None

    for message in client.paginate(
        METHOD, params, "messages",
        page_size=PAGE_SIZE, cursor_param="cursor", max_retries=8, credential="admin",
        page_param="limit", cursor_field="response_metadata.next_cursor",
    ):
        try:
            messages.append(message_row(channel_id, message))
        except (KeyError, TypeError, ValueError) as exc:
            if counts:
                counts.rows_rejected += 1
            dead_letter(conn, SOURCE, {"channel": channel_id, "keys": sorted(message)}, str(exc))
            continue
        observations.append((channel_id, message["ts"], TRANSPORT))
        thread = thread_row(channel_id, message)
        if thread:
            threads.append(thread)
        seen += 1
        ts = message["ts"]
        oldest_ts = ts if oldest_ts is None or ts < oldest_ts else oldest_ts
        newest_ts = ts if newest_ts is None or ts > newest_ts else newest_ts

    with conn.cursor() as cur:
        if messages:
            cur.executemany(MESSAGE_SQL, messages)
            cur.executemany(OBSERVATION_SQL, observations)
        if threads:
            cur.executemany(THREAD_SQL, threads)
        cur.execute(WALK_SQL, (channel_id, oldest_ts, newest_ts, seen, complete))
    conn.commit()
    return seen


def run(conn, limit=200, full=False, channels=None):
    client = ProxyClient()
    with conn.cursor() as cur:
        if channels:
            cur.execute(
                "SELECT d.channel_id, w.newest_ts FROM raw.channel_dim d "
                "LEFT JOIN raw.channel_walk w ON w.channel_id = d.channel_id "
                "WHERE d.channel_id = ANY(%s)", (list(channels),))
        else:
            cur.execute(TARGETS_SQL, (limit,))
        targets = cur.fetchall()

    if not targets:
        print(f"{SOURCE}: nothing to walk")
        return 0

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(targets)
        for channel_id, newest in targets:
            oldest = None if full or not newest else revisit_from(newest)
            try:
                counts.rows_in += walk_channel(conn, client, channel_id, oldest, counts)
            except Exception as exc:
                conn.rollback()
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO raw.channel_walk (channel_id, last_error, updated_at) "
                        "VALUES (%s, %s, now()) ON CONFLICT (channel_id) DO UPDATE SET "
                        "last_error = EXCLUDED.last_error, updated_at = now()",
                        (channel_id, str(exc)[:400]))
                conn.commit()
                counts.rows_rejected += 1
            counts.progress()

        with conn.cursor() as cur:
            cur.execute(PRICE_SQL, ([c for c, _ in targets],))
        conn.commit()

    print(f"{SOURCE}: {len(targets)} channel(s), {counts.rows_in} messages, "
          f"{counts.rows_rejected} channel(s) failed")
    return counts.rows_in


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=200)
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--channel", action="append")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, limit=args.limit, full=args.full, channels=args.channel)


if __name__ == "__main__":
    main()
