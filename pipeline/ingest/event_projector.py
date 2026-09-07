import argparse
import hashlib
import json
from datetime import datetime, timezone

from dotenv import load_dotenv
from psycopg.types.json import Jsonb

from lib.db import connect, ingest_run
from lib.message import author_kind
from lib.paths import ENV_FILE

SOURCE = "event_projector"
TRANSPORT = "event"
BATCH_LIMIT = 5000

PENDING_SQL = """
SELECT event_id, channel_id, ts, envelope, shape
FROM raw.event_delivery
WHERE projected_at IS NULL
ORDER BY received_at
LIMIT %s
"""

LATEST_SQL = """
SELECT revision, payload_hash
FROM archive.envelope
WHERE channel_id = %s AND ts = %s
ORDER BY revision DESC
LIMIT 1
"""

ENVELOPE_SQL = """
INSERT INTO archive.envelope
    (channel_id, ts, revision, payload, payload_hash, method)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (channel_id, ts, revision) DO NOTHING
"""

MESSAGE_SQL = """
INSERT INTO archive.message
    (channel_id, ts, revision, posted_at, author_id, author_kind, bot_id, app_id,
     parent_user_id, subtype, thread_root_ts, is_reply, is_broadcast,
     reply_count, reply_users_count, latest_reply_ts,
     text_length, has_text, block_count, attachment_count, file_count,
     mention_count, mentioned_ids, is_question, is_substantive, has_link, emoji_only,
     reaction_count, reactor_count, edited_at, edited_by, client_msg_id, team_id, settled)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, false)
ON CONFLICT (channel_id, ts) DO UPDATE SET
    revision = EXCLUDED.revision,
    posted_at = EXCLUDED.posted_at,
    author_id = coalesce(EXCLUDED.author_id, archive.message.author_id),
    author_kind = EXCLUDED.author_kind,
    bot_id = coalesce(EXCLUDED.bot_id, archive.message.bot_id),
    app_id = coalesce(EXCLUDED.app_id, archive.message.app_id),
    parent_user_id = coalesce(EXCLUDED.parent_user_id, archive.message.parent_user_id),
    subtype = coalesce(EXCLUDED.subtype, archive.message.subtype),
    thread_root_ts = coalesce(EXCLUDED.thread_root_ts, archive.message.thread_root_ts),
    is_reply = EXCLUDED.is_reply,
    is_broadcast = EXCLUDED.is_broadcast,
    reply_count = coalesce(EXCLUDED.reply_count, archive.message.reply_count),
    reply_users_count = coalesce(EXCLUDED.reply_users_count, archive.message.reply_users_count),
    latest_reply_ts = coalesce(EXCLUDED.latest_reply_ts, archive.message.latest_reply_ts),
    text_length = coalesce(EXCLUDED.text_length, archive.message.text_length),
    has_text = coalesce(EXCLUDED.has_text, archive.message.has_text),
    block_count = coalesce(EXCLUDED.block_count, archive.message.block_count),
    attachment_count = coalesce(EXCLUDED.attachment_count, archive.message.attachment_count),
    file_count = coalesce(EXCLUDED.file_count, archive.message.file_count),
    mention_count = coalesce(EXCLUDED.mention_count, archive.message.mention_count),
    mentioned_ids = coalesce(EXCLUDED.mentioned_ids, archive.message.mentioned_ids),
    is_question = coalesce(EXCLUDED.is_question, archive.message.is_question),
    is_substantive = coalesce(EXCLUDED.is_substantive, archive.message.is_substantive),
    has_link = coalesce(EXCLUDED.has_link, archive.message.has_link),
    emoji_only = coalesce(EXCLUDED.emoji_only, archive.message.emoji_only),
    reaction_count = coalesce(EXCLUDED.reaction_count, archive.message.reaction_count),
    reactor_count = coalesce(EXCLUDED.reactor_count, archive.message.reactor_count),
    edited_at = coalesce(EXCLUDED.edited_at, archive.message.edited_at),
    edited_by = coalesce(EXCLUDED.edited_by, archive.message.edited_by),
    client_msg_id = coalesce(EXCLUDED.client_msg_id, archive.message.client_msg_id),
    team_id = coalesce(EXCLUDED.team_id, archive.message.team_id),
    updated_at = now()
WHERE NOT archive.message.settled
"""

OBSERVED_SQL = """
INSERT INTO archive.observation (channel_id, ts, transport, revision)
VALUES (%s, %s, %s, %s)
ON CONFLICT (channel_id, ts, transport, revision) DO UPDATE SET observed_at = now()
"""

DELETED_SQL = """
UPDATE archive.message
SET deleted_at = coalesce(%s, now()), updated_at = now()
WHERE channel_id = %s AND ts = %s AND deleted_at IS NULL
"""

DONE_SQL = "UPDATE raw.event_delivery SET projected_at = now() WHERE event_id = ANY(%s)"

GONE = "message_deleted"
CHANGED = "message_changed"
WRAPPERS = frozenset({GONE, CHANGED})


def stamp(ts):
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc)
    except (TypeError, ValueError):
        return None


def digest(payload):
    packed = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(packed.encode("utf-8")).digest()


def body_of(envelope):
    if envelope.get("type") != "message":
        return None
    if envelope.get("subtype") == GONE:
        return None
    if envelope.get("subtype") == CHANGED:
        changed = envelope.get("message")
        return changed if isinstance(changed, dict) else None
    return envelope


def revision_for(conn, channel_id, ts, payload_hash):
    with conn.cursor() as cur:
        cur.execute(LATEST_SQL, (channel_id, ts))
        row = cur.fetchone()
    if row is None:
        return 1, True
    revision, held = row
    return (revision, False) if bytes(held) == payload_hash else (revision + 1, True)


def message_row(channel_id, ts, revision, envelope, measured):
    body = body_of(envelope)
    if body is None:
        return None

    posted = stamp(ts)
    if posted is None:
        return None

    thread_root = body.get("thread_ts")
    edited = body.get("edited") or {}
    counted = measured or {}
    wrapper = envelope.get("subtype")
    subtype = body.get("subtype") or (None if wrapper in WRAPPERS else wrapper)
    return (
        channel_id, ts, revision, posted,
        body.get("user") or envelope.get("user"),
        author_kind(body),
        body.get("bot_id"),
        body.get("app_id"),
        body.get("parent_user_id"),
        subtype,
        thread_root,
        bool(thread_root) and thread_root != ts,
        body.get("subtype") == "thread_broadcast",
        body.get("reply_count"),
        body.get("reply_users_count"),
        body.get("latest_reply"),
        counted.get("text_length"),
        counted.get("has_text"),
        counted.get("block_count"),
        counted.get("attachment_count"),
        counted.get("file_count"),
        counted.get("mention_count"),
        counted.get("mentioned_ids"),
        counted.get("is_question"),
        counted.get("is_substantive"),
        counted.get("has_link"),
        counted.get("emoji_only"),
        counted.get("reaction_count"),
        counted.get("reactor_count"),
        stamp(edited.get("ts")) if edited.get("ts") else None,
        edited.get("user"),
        body.get("client_msg_id"),
        body.get("team") or body.get("source_team"),
    )


def erase(conn, channel_id, ts, envelope, counts):
    when = stamp(envelope.get("event_ts"))
    with conn.cursor() as cur:
        cur.execute(DELETED_SQL, (when, channel_id, ts))
        if cur.rowcount:
            counts.rows_in += 1


def project(conn, row, counts):
    event_id, channel_id, ts, envelope, measured = row
    if not channel_id or not ts or not isinstance(envelope, dict):
        counts.rows_rejected += 1
        return event_id

    if envelope.get("type") == "message" and envelope.get("subtype") == GONE:
        erase(conn, channel_id, ts, envelope, counts)
        return event_id

    if body_of(envelope) is None:
        return event_id

    payload_hash = digest(envelope)
    revision, fresh = revision_for(conn, channel_id, ts, payload_hash)

    with conn.cursor() as cur:
        if fresh:
            cur.execute(ENVELOPE_SQL, (channel_id, ts, revision, Jsonb(envelope),
                                       payload_hash, TRANSPORT))
        built = message_row(channel_id, ts, revision, envelope, measured)
        if built is None:
            counts.rows_rejected += 1
            return event_id
        cur.execute(MESSAGE_SQL, built)
        cur.execute(OBSERVED_SQL, (channel_id, ts, TRANSPORT, revision))
    counts.rows_in += 1
    return event_id


def pending(conn, limit):
    with conn.cursor() as cur:
        cur.execute(PENDING_SQL, (limit,))
        return cur.fetchall()


def run(conn, limit=BATCH_LIMIT):
    waiting = pending(conn, limit)
    if not waiting:
        print(f"{SOURCE}: nothing to project")
        return 0

    with ingest_run(conn, SOURCE) as counts:
        done = [project(conn, row, counts) for row in waiting]
        with conn.cursor() as cur:
            cur.execute(DONE_SQL, (done,))
        conn.commit()
    print(f"{SOURCE}: {counts.rows_in} message(s) projected from {len(done)} event(s), "
          f"{counts.rows_rejected} rejected")
    return len(done)


def main():
    load_dotenv(ENV_FILE)
    parser = argparse.ArgumentParser(prog=SOURCE)
    parser.add_argument("--limit", type=int, default=BATCH_LIMIT)
    asked = parser.parse_args()
    with connect() as conn:
        run(conn, asked.limit)


if __name__ == "__main__":
    main()
