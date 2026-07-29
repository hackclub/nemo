import json
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, get_cursor, ingest_run, save_cursor
from lib.proxy_client import ProxyClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "admin_analytics_messages_activity"

MESSAGE_ACTIVITY_SQL = """
INSERT INTO raw.message_activity_snapshot
    (channel_id, message_ts, source, unique_user_views_count, unique_user_reactions_count,
     unique_user_shares_count, unique_user_clicks_count, views_client, stats_by_department, stats_by_org)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (channel_id, message_ts, source) DO UPDATE SET
    unique_user_views_count = EXCLUDED.unique_user_views_count,
    unique_user_reactions_count = EXCLUDED.unique_user_reactions_count,
    unique_user_shares_count = EXCLUDED.unique_user_shares_count,
    unique_user_clicks_count = EXCLUDED.unique_user_clicks_count,
    views_client = EXCLUDED.views_client,
    stats_by_department = EXCLUDED.stats_by_department,
    stats_by_org = EXCLUDED.stats_by_org,
    pulled_at = now()
"""


def message_activity_row(rec):
    views_client = rec.get("unique_views_client")
    stats_by_department = rec.get("unique_stats_by_department")
    stats_by_org = rec.get("unique_stats_by_org")
    return (
        rec["channel_id"],
        rec["timestamp"],
        SOURCE,
        rec.get("unique_user_views_count"),
        rec.get("unique_user_reactions_count"),
        rec.get("unique_user_shares_count"),
        rec.get("unique_user_clicks_count"),
        json.dumps(views_client) if views_client is not None else None,
        json.dumps(stats_by_department) if stats_by_department is not None else None,
        json.dumps(stats_by_org) if stats_by_org is not None else None,
    )


def known_channel_ids(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT channel_id FROM raw.channel_dim WHERE coalesce(archived, false) = false")
        return [row[0] for row in cur.fetchall()]


def pull_channel_message_activity(conn, channel_id):
    with ingest_run(conn, f"{SOURCE}:{channel_id}") as counts:
        client = ProxyClient()
        cursor = get_cursor(conn, SOURCE, channel_id)
        while True:
            params = {"channel": channel_id, "limit": 100}
            if cursor:
                params["cursor"] = cursor
            data = client.call("admin.analytics.messages.activity", params, credential="admin")
            rows = []
            for rec in data.get("message_activities", []):
                counts.rows_in += 1
                try:
                    rows.append(message_activity_row(rec))
                except KeyError as exc:
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, rec, str(exc))
            with conn.cursor() as cur:
                cur.executemany(MESSAGE_ACTIVITY_SQL, rows)
            cursor = data.get("response_metadata", {}).get("next_cursor") or ""
            save_cursor(conn, SOURCE, cursor, channel_id)
            conn.commit()
            if not cursor:
                break
    print(f"message activity {channel_id}: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def pull_all_channels(conn):
    for channel_id in known_channel_ids(conn):
        try:
            pull_channel_message_activity(conn, channel_id)
        except Exception as exc:
            conn.rollback()
            dead_letter(conn, SOURCE, {"channel_id": channel_id}, str(exc))
            conn.commit()
            print(f"message activity {channel_id}: ERROR {exc}")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        pull_all_channels(conn)


if __name__ == "__main__":
    main()
