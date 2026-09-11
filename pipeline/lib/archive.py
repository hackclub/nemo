import hashlib
import json
from datetime import datetime, timezone

from psycopg.types.json import Jsonb

from lib.message import author_kind, scrub, shape

GONE = "message_deleted"
CHANGED = "message_changed"
WRAPPERS = frozenset({GONE, CHANGED})

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

FIELDS = (
    "channel_id", "ts", "revision", "posted_at", "author_id", "author_kind", "bot_id",
    "app_id", "parent_user_id", "subtype", "thread_root_ts", "is_reply", "is_broadcast",
    "reply_count", "reply_users_count", "latest_reply_ts", "text_length", "has_text",
    "block_count", "attachment_count", "file_count", "mention_count", "mentioned_ids",
    "is_question", "is_substantive", "has_link", "emoji_only", "reaction_count",
    "reactor_count", "edited_at", "edited_by", "client_msg_id", "team_id",
)

KEPT_WHEN_ABSENT = (
    "author_id", "bot_id", "app_id", "parent_user_id", "subtype", "text_length", "has_text",
    "block_count", "attachment_count", "file_count", "mention_count", "mentioned_ids",
    "is_question", "is_substantive", "has_link", "emoji_only", "reaction_count",
    "reactor_count", "edited_at", "edited_by", "client_msg_id", "team_id",
)

ALWAYS = ("revision", "posted_at", "author_kind", "is_reply", "is_broadcast",
          "thread_root_ts", "reply_count", "reply_users_count", "latest_reply_ts")


def _upsert():
    columns = ", ".join(FIELDS)
    holders = ", ".join(["%s"] * len(FIELDS))
    kept = [f"{name} = coalesce(EXCLUDED.{name}, archive.message.{name})"
            for name in KEPT_WHEN_ABSENT]
    plain = [f"{name} = EXCLUDED.{name}" for name in ALWAYS]
    sets = ", ".join(plain + kept + ["settled = archive.message.settled OR EXCLUDED.settled",
                                     "updated_at = now()"])
    return (
        f"INSERT INTO archive.message ({columns}, settled) VALUES ({holders}, %s) "
        f"ON CONFLICT (channel_id, ts) DO UPDATE SET {sets} "
        f"WHERE NOT archive.message.settled OR EXCLUDED.settled"
    )


MESSAGE_SQL = _upsert()

OBSERVED_SQL = """
INSERT INTO archive.observation (channel_id, ts, transport, revision)
VALUES (%s, %s, %s, %s)
ON CONFLICT (channel_id, ts, transport, revision) DO UPDATE SET observed_at = now()
"""

LOCK_SQL = "SELECT pg_advisory_xact_lock(hashtext(%s))"

TOMBSTONE_SQL = """
INSERT INTO archive.message
    (channel_id, ts, revision, posted_at, author_kind, deleted_at, settled)
VALUES (%s, %s, 1, %s, 'unknown', coalesce(%s, now()), false)
ON CONFLICT (channel_id, ts) DO NOTHING
"""

DELETED_SQL = """
UPDATE archive.message
SET deleted_at = coalesce(%s, now()), updated_at = now()
WHERE channel_id = %s AND ts = %s AND deleted_at IS NULL
"""


def stamp(ts):
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc)
    except (TypeError, ValueError):
        return None


def digest(payload):
    packed = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(packed.encode("utf-8")).digest()


def body_of(envelope):
    if envelope.get("type") not in (None, "message"):
        return None
    if envelope.get("subtype") == GONE:
        return None
    if envelope.get("subtype") == CHANGED:
        changed = envelope.get("message")
        return changed if isinstance(changed, dict) else None
    return envelope


def hold(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(LOCK_SQL, (channel_id,))


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
        body.get("user") or body.get("bot_id") or envelope.get("user"),
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


LATEST_MANY_SQL = """
SELECT ts, revision, payload_hash
FROM (
    SELECT ts, revision, payload_hash,
           row_number() OVER (PARTITION BY ts ORDER BY revision DESC) AS rn
    FROM archive.envelope
    WHERE channel_id = %s AND ts = ANY(%s)
) latest
WHERE rn = 1
"""


def latest_for(conn, channel_id, stamps):
    if not stamps:
        return {}
    with conn.cursor() as cur:
        cur.execute(LATEST_MANY_SQL, (channel_id, list(stamps)))
        return {ts: (revision, bytes(held)) for ts, revision, held in cur.fetchall()}


def next_revision(held, payload_hash):
    if held is None:
        return 1, True
    revision, kept = held
    return (revision, False) if kept == payload_hash else (revision + 1, True)


def record_many(conn, channel_id, entries, method, transport, settled, on_reject=None):
    def refuse(ts, reason):
        if on_reject is not None:
            on_reject(ts, reason)

    shaped = []
    for ts, envelope, measured in entries:
        if not channel_id or not ts or not isinstance(envelope, dict):
            refuse(ts, "no channel, no ts, or the envelope is not an object")
            continue
        if body_of(envelope) is None:
            refuse(ts, "the envelope carries no message body")
            continue
        shaped.append((ts, envelope, measured, digest(envelope)))
    if not shaped:
        return 0

    hold(conn, channel_id)
    held = latest_for(conn, channel_id, {ts for ts, *_ in shaped})
    envelopes, messages, observations = [], [], []
    for ts, envelope, measured, payload_hash in shaped:
        revision, fresh = next_revision(held.get(ts), payload_hash)
        built = message_row(channel_id, ts, revision, envelope, measured)
        if built is None:
            refuse(ts, "the envelope would not build a message row")
            continue
        if fresh:
            envelopes.append((channel_id, ts, revision, Jsonb(envelope), payload_hash, method))
        messages.append((*built, settled))
        observations.append((channel_id, ts, transport, revision))
        held[ts] = (revision, payload_hash)

    with conn.cursor() as cur:
        if envelopes:
            cur.executemany(ENVELOPE_SQL, envelopes)
        if messages:
            cur.executemany(MESSAGE_SQL, messages)
        if observations:
            cur.executemany(OBSERVED_SQL, observations)
    return len(messages)


def from_api_many(conn, channel_id, messages, method, transport, on_reject=None):
    return record_many(
        conn, channel_id,
        [(message.get("ts"), scrub(message), shape(message)) for message in messages],
        method, transport, True, on_reject=on_reject)


def record(conn, channel_id, ts, envelope, measured, method, transport, settled):
    if not channel_id or not ts or not isinstance(envelope, dict):
        return False
    if body_of(envelope) is None:
        return False

    hold(conn, channel_id)
    payload_hash = digest(envelope)
    revision, fresh = revision_for(conn, channel_id, ts, payload_hash)
    built = message_row(channel_id, ts, revision, envelope, measured)
    if built is None:
        return False

    with conn.cursor() as cur:
        if fresh:
            cur.execute(ENVELOPE_SQL,
                        (channel_id, ts, revision, Jsonb(envelope), payload_hash, method))
        cur.execute(MESSAGE_SQL, (*built, settled))
        cur.execute(OBSERVED_SQL, (channel_id, ts, transport, revision))
    return True


def from_api(conn, channel_id, message, method, transport):
    ts = message.get("ts")
    return record(conn, channel_id, ts, scrub(message), shape(message),
                  method, transport, True)


def mark_deleted(conn, channel_id, ts, when):
    with conn.cursor() as cur:
        cur.execute(DELETED_SQL, (when, channel_id, ts))
        if cur.rowcount:
            return cur.rowcount
        posted = stamp(ts)
        if posted is None:
            return 0
        cur.execute(TOMBSTONE_SQL, (channel_id, ts, posted, when))
        return cur.rowcount
