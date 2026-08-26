import argparse
import os
import time
from datetime import datetime, timezone

from dotenv import load_dotenv

from ingest.member_history import is_public
from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import InternalApiError, ProxyClient

SOURCE = "member_channels"
COHORT_DAYS = int(os.environ.get("NEWCOMER_COHORT_DAYS", "30"))
BATCH_LIMIT = int(os.environ.get("MEMBER_CHANNELS_LIMIT", "600"))
PAGE_SIZE = 100
PAGE_CAP = 100
REPORT_EVERY = 50
MIN_SECONDS_PER_SEARCH = 0.6

PENDING_SQL = """
WITH edge AS (SELECT max(claimed_at)::date AS d FROM raw.member_dim)
SELECT m.user_id
FROM raw.member_dim m
CROSS JOIN edge
LEFT JOIN raw.member_channel_walk w ON w.user_id = m.user_id
WHERE m.claimed_at >= edge.d - %s
  AND NOT coalesce(m.is_bot, false)
  AND NOT coalesce(m.is_deleted, false)
  AND NOT coalesce(m.invite_pending, false)
  AND w.messages_searched_at IS NULL
ORDER BY m.claimed_at DESC
LIMIT %s
"""

CLEAR_SQL = "DELETE FROM raw.member_channel_message WHERE user_id = %s"

MERGE_SQL = """
INSERT INTO raw.member_channel_message
    (user_id, channel_id, messages, first_ts, last_ts, searched_at)
VALUES (%s, %s, %s, %s, %s, now())
ON CONFLICT (user_id, channel_id) DO UPDATE SET
    messages = EXCLUDED.messages,
    first_ts = EXCLUDED.first_ts,
    last_ts = EXCLUDED.last_ts,
    searched_at = now()
"""

WALK_SQL = """
INSERT INTO raw.member_channel_walk (user_id, messages_searched_at, pages, truncated)
VALUES (%s, now(), %s, %s)
ON CONFLICT (user_id) DO UPDATE SET
    messages_searched_at = now(),
    pages = EXCLUDED.pages,
    truncated = EXCLUDED.truncated,
    updated_at = now()
"""


def stamp(value):
    return datetime.fromtimestamp(float(value), tz=timezone.utc)


def tally_page(tally, matches):
    for match in matches:
        if not is_public(match):
            continue
        channel_id = (match.get("channel") or {}).get("id")
        at = stamp(match["ts"])
        if channel_id is None:
            continue
        counted = tally.get(channel_id)
        if counted is None:
            tally[channel_id] = [1, at, at]
        else:
            counted[0] += 1
            counted[1] = min(counted[1], at)
            counted[2] = max(counted[2], at)
    return tally


def keep_paging(messages, asked, seen):
    paging = messages.get("paging") or {}
    if paging.get("page") != asked:
        return False
    if asked >= PAGE_CAP:
        return False
    if len(messages.get("matches") or []) < PAGE_SIZE:
        return False
    return seen < (paging.get("total") or 0)


def message_rows(user_id, tally):
    return [
        (user_id, channel_id, messages, first_ts, last_ts)
        for channel_id, (messages, first_ts, last_ts) in sorted(tally.items())
    ]


def search_page(client, team_id, user_id, page):
    return client.call(
        "search.messages",
        {
            "query": f"from:<@{user_id}>",
            "sort": "timestamp",
            "sort_dir": "asc",
            "count": PAGE_SIZE,
            "page": page,
            "team_id": team_id,
        },
        credential="admin",
    )


def walk_member(client, team_id, user_id):
    tally, page, seen = {}, 1, 0
    while True:
        messages = search_page(client, team_id, user_id, page).get("messages") or {}
        matches = messages.get("matches") or []
        seen += len(matches)
        tally_page(tally, matches)
        if not keep_paging(messages, page, seen):
            break
        page += 1
    total = (messages.get("paging") or {}).get("total") or 0
    return tally, page, seen < total


def write_member(conn, user_id, tally, pages, truncated):
    with conn.cursor() as cur:
        cur.execute(CLEAR_SQL, (user_id,))
        rows = message_rows(user_id, tally)
        if rows:
            cur.executemany(MERGE_SQL, rows)
        cur.execute(WALK_SQL, (user_id, pages, truncated))
    conn.commit()
    return len(rows)


def pending_members(conn, cohort_days, limit):
    with conn.cursor() as cur:
        cur.execute(PENDING_SQL, (cohort_days, limit))
        return [row[0] for row in cur.fetchall()]


def run(conn, limit=BATCH_LIMIT, cohort_days=COHORT_DAYS):
    members = pending_members(conn, cohort_days, limit)
    if not members:
        print(f"{SOURCE}: every newcomer of the last {cohort_days} days is walked")
        return 0

    client = ProxyClient()
    team_id = os.environ["SLACK_TEAM_ID"]
    print(f"{SOURCE}: {len(members)} newcomer(s) to walk, newest first")

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(members)
        channels, cut_short = 0, 0

        for user_id in members:
            started = time.monotonic()
            try:
                tally, pages, truncated = walk_member(client, team_id, user_id)
            except InternalApiError as exc:
                conn.rollback()
                counts.rows_rejected += 1
                dead_letter(conn, SOURCE, {"user_id": user_id}, str(exc))
                conn.commit()
                continue
            channels += write_member(conn, user_id, tally, pages, truncated)
            cut_short += int(truncated)
            counts.rows_in += 1
            if counts.rows_in % REPORT_EVERY == 0:
                counts.progress()
                print(f"{SOURCE}: {counts.rows_in}/{len(members)} walked, {channels} channel rows")
            time.sleep(max(0.0, MIN_SECONDS_PER_SEARCH - (time.monotonic() - started)))

        counts.progress()

    print(
        f"{SOURCE}: {counts.rows_in} walked, {channels} channel rows, "
        f"{cut_short} cut short at {PAGE_CAP} pages, {counts.rows_rejected} rejected"
    )
    return len(members)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=BATCH_LIMIT)
    parser.add_argument("--cohort-days", type=int, default=COHORT_DAYS)
    parser.add_argument("--burst", action="store_true")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    with connect() as conn:
        if args.burst:
            while run(conn, args.limit, args.cohort_days):
                pass
        else:
            run(conn, args.limit, args.cohort_days)


if __name__ == "__main__":
    main()
