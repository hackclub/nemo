import argparse

from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

REVISION = 0

OWED_SQL = """
SELECT s.channel_id, count(*)
FROM raw.message s
LEFT JOIN archive.message a ON a.channel_id = s.channel_id AND a.ts = s.ts
WHERE a.ts IS NULL
GROUP BY 1
ORDER BY 2 DESC
"""

UNUSABLE_SQL = """
SELECT count(*)
FROM raw.message s
LEFT JOIN archive.message a ON a.channel_id = s.channel_id AND a.ts = s.ts
WHERE a.ts IS NULL AND (s.posted_at IS NULL OR s.ts IS NULL)
"""

MESSAGE_SQL = """
INSERT INTO archive.message (
    channel_id, ts, revision, posted_at, author_id, author_kind, subtype,
    thread_root_ts, is_reply, is_broadcast, reply_count, reply_users_count,
    latest_reply_ts, text_length, has_text, file_count, mention_count, mentioned_ids,
    is_question, is_substantive, has_link, emoji_only, reaction_count, reactor_count,
    edited_at, edited_by, settled, first_seen_at)
SELECT
    s.channel_id,
    s.ts,
    %(revision)s,
    s.posted_at,
    s.author_id,
    coalesce(s.author_kind, 'unknown'),
    s.subtype,
    s.thread_root_ts,
    coalesce(s.is_reply, false),
    coalesce(s.subtype = 'thread_broadcast', false),
    s.reply_count,
    s.reply_users_count,
    s.latest_reply_ts,
    s.text_length,
    CASE WHEN s.text_length IS NULL THEN NULL ELSE s.text_length > 0 END,
    s.file_count,
    s.mention_count,
    s.mentioned_ids,
    s.is_question,
    s.is_substantive,
    s.has_link,
    s.emoji_only,
    s.reaction_count,
    s.reactor_count,
    s.edited_at,
    s.edited_by,
    false,
    coalesce(s.observed_at, now())
FROM raw.message s
WHERE s.channel_id = %(channel)s AND s.ts IS NOT NULL AND s.posted_at IS NOT NULL
ON CONFLICT (channel_id, ts) DO NOTHING
"""

OBSERVED_SQL = """
INSERT INTO archive.observation (channel_id, ts, transport, revision, observed_at)
SELECT o.channel_id, o.ts, o.transport, %(revision)s, o.observed_at
FROM raw.message_observation o
JOIN archive.message a
  ON a.channel_id = o.channel_id AND a.ts = o.ts AND a.revision = %(revision)s
WHERE o.channel_id = %(channel)s
ON CONFLICT (channel_id, ts, transport, revision) DO NOTHING
"""

HELD_SQL = "SELECT count(*) FROM archive.message"


def owed(conn):
    with conn.cursor() as cur:
        cur.execute(OWED_SQL)
        return cur.fetchall()


def unusable(conn):
    with conn.cursor() as cur:
        cur.execute(UNUSABLE_SQL)
        return cur.fetchone()[0]


def held(conn):
    with conn.cursor() as cur:
        cur.execute(HELD_SQL)
        return cur.fetchone()[0]


def fill(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(MESSAGE_SQL, {"channel": channel_id, "revision": REVISION})
        messages = cur.rowcount
        cur.execute(OBSERVED_SQL, {"channel": channel_id, "revision": REVISION})
        observations = cur.rowcount
    conn.commit()
    return messages, observations


def run(conn, dry_run=False, every=25, quiet=False):
    queue = owed(conn)
    skipped = unusable(conn)
    total = sum(count for _, count in queue)

    if quiet:
        messages = 0
        for channel_id, _ in queue:
            wrote, _ = fill(conn, channel_id)
            messages += wrote
        return messages

    print(f"{total} message(s) the archive does not hold, across {len(queue)} channel(s)")
    if skipped:
        print(f"{skipped} of those carry no ts or no posted_at and cannot be seeded")
    if dry_run:
        for channel_id, count in queue[:10]:
            print(f"  would seed {count:>7} from {channel_id}")
        if len(queue) > 10:
            print(f"  and {len(queue) - 10} more channel(s)")
        return 0

    before = held(conn)
    messages = observations = 0
    for done, (channel_id, count) in enumerate(queue, start=1):
        wrote, observed = fill(conn, channel_id)
        messages += wrote
        observations += observed
        if done % every == 0 or done == len(queue):
            print(f"  {done}/{len(queue)} channel(s), {messages} message(s) seeded")

    after = held(conn)
    print(f"seeded {messages} message(s) at revision {REVISION} and {observations} observation(s)")
    print(f"archive.message went from {before} to {after} row(s)")
    left = sum(count for _, count in owed(conn))
    print(f"{left} message(s) still only in raw.message")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="copy every raw.message row the archive does not hold into archive.message")
    parser.add_argument("--dry-run", action="store_true", help="report what would be seeded")
    parser.add_argument("--dsn", help="connect to this Postgres DSN instead of the pipeline's own env")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    with connect(args.dsn) as conn:
        return run(conn, dry_run=args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
