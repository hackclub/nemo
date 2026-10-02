import argparse
import os

from dotenv import load_dotenv

from lib import work
from lib.db import connect, ingest_run
from lib.paths import ENV_FILE
from lib.slack_client import bot_client
from lib.task import per_entity

MEMBERSHIP_SOURCE = "channel_membership"
COHORT_DAYS = int(os.environ.get("NEWCOMER_COHORT_DAYS", "30"))
BATCH_LIMIT = int(os.environ.get("MEMBER_CHANNELS_LIMIT", "600"))
MEMBERSHIP_PAGE = 999
REPORT_EVERY = 50

MEMBERSHIP_KIND = "channel_membership"


def queue_select(kind, body):
    return f"""
SELECT p.user_id AS target_key, '' AS target_sub_key, 100 AS priority, '{{}}'::jsonb AS payload,
       NULL::integer AS expected
FROM ({body.replace('%s', '%(p0)s')}) p
LEFT JOIN ingest.work_item w
       ON w.work_kind = '{kind}' AND w.target_key = p.user_id AND w.target_sub_key = ''
WHERE w.work_item_id IS NULL
"""

UNREAD_BODY = """
WITH edge AS MATERIALIZED (SELECT max(claimed_at)::date AS d FROM raw.member_dim)
SELECT m.user_id
FROM raw.member_dim m
CROSS JOIN edge
LEFT JOIN raw.member_channel_walk w ON w.user_id = m.user_id
WHERE m.claimed_at >= edge.d - %s
  AND NOT coalesce(m.is_bot, false)
  AND NOT coalesce(m.is_deleted, false)
  AND NOT coalesce(m.invite_pending, false)
  AND w.membership_read_at IS NULL
ORDER BY m.claimed_at DESC
"""

UNREAD_SQL = UNREAD_BODY + "LIMIT %s"

LEFT_SQL = """
DELETE FROM raw.member_channel_membership
WHERE user_id = %s AND channel_id <> ALL(%s)
"""

JOINED_SQL = """
INSERT INTO raw.member_channel_membership (user_id, channel_id, seen_at)
VALUES (%s, %s, now())
ON CONFLICT (user_id, channel_id) DO UPDATE SET seen_at = now()
"""

READ_SQL = """
INSERT INTO raw.member_channel_walk (user_id, membership_read_at)
VALUES (%s, now())
ON CONFLICT (user_id) DO UPDATE SET
    membership_read_at = now(),
    updated_at = now()
"""


def enqueue_newcomers(conn, kind, body, cohort_days, requested_by):
    return work.enqueue_select(conn, kind, queue_select(kind, body), (cohort_days,), requested_by=requested_by)


def joined_channels(channels):
    return sorted({
        channel["id"] for channel in channels
        if channel.get("is_channel") and not channel.get("is_private")
        and not channel.get("is_archived")
    })


def read_member(client, team_id, user_id):
    channels, cursor = [], None
    while True:
        resp = client.users_conversations(
            user=user_id,
            types="public_channel",
            exclude_archived=True,
            limit=MEMBERSHIP_PAGE,
            team_id=team_id,
            cursor=cursor,
        )
        channels += resp.get("channels") or []
        cursor = (resp.get("response_metadata") or {}).get("next_cursor") or None
        if not cursor:
            return joined_channels(channels)


def write_membership(conn, user_id, channel_ids):
    with conn.cursor() as cur:
        cur.execute(LEFT_SQL, (user_id, channel_ids))
        left = cur.rowcount
        for channel_id in channel_ids:
            cur.execute(JOINED_SQL, (user_id, channel_id))
        cur.execute(READ_SQL, (user_id,))
    conn.commit()
    return left


def unread_members(conn, cohort_days, limit):
    with conn.cursor() as cur:
        cur.execute(UNREAD_SQL, (cohort_days, limit))
        return [row[0] for row in cur.fetchall()]


def read_membership(conn, client=None, limit=BATCH_LIMIT, cohort_days=COHORT_DAYS):
    work.reclaim(conn, MEMBERSHIP_KIND)
    queued = enqueue_newcomers(conn, MEMBERSHIP_KIND, UNREAD_BODY, cohort_days, MEMBERSHIP_SOURCE)
    items = work.claim(conn, MEMBERSHIP_KIND, limit)
    if not items:
        print(f"{MEMBERSHIP_SOURCE}: every newcomer of the last {cohort_days} days is read, queue empty")
        return 0

    client = client or bot_client()
    team_id = os.environ["SLACK_TEAM_ID"]
    print(f"{MEMBERSHIP_SOURCE}: {len(items)} newcomer(s) claimed off the queue"
          + (f", {queued} newly queued" if queued else ""))

    with ingest_run(conn, MEMBERSHIP_SOURCE) as counts:
        counts.total_expected = len(items)
        joined, left = 0, 0

        for item in items:
            with per_entity(conn, MEMBERSHIP_SOURCE, counts, {"user_id": item.target_key},
                            on_fault=lambda fault, item=item: work.fail(conn, item, fault.detail)):
                channel_ids = read_member(client, team_id, item.target_key)
                left += write_membership(conn, item.target_key, channel_ids)
                joined += len(channel_ids)
                work.settle(conn, item, "complete", fetched=len(channel_ids))
                conn.commit()
                counts.rows_in += 1
            if counts.rows_in % REPORT_EVERY == 0:
                counts.progress()
                print(f"{MEMBERSHIP_SOURCE}: {counts.rows_in}/{len(items)} read, {joined} memberships")

        counts.progress()

    print(
        f"{MEMBERSHIP_SOURCE}: {counts.rows_in} read, {joined} memberships, "
        f"{left} dropped, {counts.rows_rejected} rejected"
    )
    return len(items)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=BATCH_LIMIT)
    parser.add_argument("--cohort-days", type=int, default=COHORT_DAYS)
    parser.add_argument("--burst", action="store_true")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    with connect() as conn:
        if args.burst:
            while read_membership(conn, limit=args.limit, cohort_days=args.cohort_days):
                pass
        else:
            read_membership(conn, limit=args.limit, cohort_days=args.cohort_days)


if __name__ == "__main__":
    main()
