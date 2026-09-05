import os
import sys

from dotenv import load_dotenv
from slack_sdk.errors import SlackApiError

from lib.db import connect, get_cursor, ingest_run, save_cursor
from lib.paths import ENV_FILE
from lib.slack_client import bot_client
from lib.task import per_entity

SOURCE = "channel_roster"
NAME_SOURCE = "channel_info_names"
NAME_COMMIT_EVERY = 100
TEAM_ERRORS = ("team_not_found", "team_access_not_granted", "invalid_team_id")
UNREACHABLE_ERRORS = (
    "channel_not_found",
    "team_access_not_granted",
    "method_not_supported_for_channel_type",
)

CHANNEL_NAME_SQL = """
INSERT INTO raw.channel_dim (channel_id, name, archived, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET
    name = EXCLUDED.name,
    archived = EXCLUDED.archived,
    name_unavailable = false,
    updated_at = now()
"""

MARK_UNREACHABLE_SQL = """
UPDATE raw.channel_dim SET name_unavailable = true, updated_at = now() WHERE channel_id = %s
"""

ARCHIVE_UNSEEN_SQL = """
UPDATE raw.channel_dim
SET archived = true, updated_at = now()
WHERE coalesce(archived, false) = false AND channel_id <> ALL(%s)
"""


def resolve_team_id():
    configured = os.environ.get("SLACK_TEAM_ID", "").strip()
    if not configured:
        raise RuntimeError("SLACK_TEAM_ID must be set to the workspace the channel roster lists")
    return configured


def list_public_channels(client, team_id, cursor):
    try:
        return client.conversations_list(
            types="public_channel", exclude_archived=True, limit=200,
            team_id=team_id, cursor=cursor,
        )
    except SlackApiError as exc:
        error = exc.response.get("error")
        if error not in TEAM_ERRORS:
            raise
        raise RuntimeError(
            f"SLACK_TEAM_ID {team_id} is not a workspace this bot can read: {error}"
        ) from exc


def record_channel_names(conn, client):
    team_id = resolve_team_id()
    with ingest_run(conn, SOURCE) as counts:
        cursor = get_cursor(conn, SOURCE)
        started_fresh = not cursor
        seen = []
        while True:
            page = list_public_channels(client, team_id, cursor)
            for channel in page.get("channels", []):
                counts.rows_in += 1
                seen.append(channel["id"])
                with conn.cursor() as cur:
                    cur.execute(CHANNEL_NAME_SQL, (channel["id"], channel.get("name"), channel.get("is_archived", False)))
            cursor = page.get("response_metadata", {}).get("next_cursor") or ""
            save_cursor(conn, SOURCE, cursor)
            conn.commit()
            if not cursor:
                break
        newly_archived = 0
        if started_fresh and seen:
            with conn.cursor() as cur:
                cur.execute(ARCHIVE_UNSEEN_SQL, (seen,))
                newly_archived = cur.rowcount
            conn.commit()
    print(f"{SOURCE}: {counts.rows_in} channels named, {newly_archived} marked archived, "
          f"{counts.rows_rejected} failed")


def name_unknown(conn, client):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT channel_id FROM raw.channel_dim "
            "WHERE name IS NULL AND coalesce(name_unavailable, false) = false"
        )
        pending = [row[0] for row in cur.fetchall()]

    with ingest_run(conn, NAME_SOURCE) as counts:
        for channel_id in pending:
            counts.rows_in += 1

            def unreachable(fault, channel_id=channel_id):
                counts.rows_rejected += 1
                with conn.cursor() as cur:
                    cur.execute(MARK_UNREACHABLE_SQL, (channel_id,))
                conn.commit()

            with per_entity(conn, NAME_SOURCE, counts, {"channel_id": channel_id}, on_entity=unreachable):
                channel = client.conversations_info(channel=channel_id)["channel"]
                with conn.cursor() as cur:
                    cur.execute(
                        CHANNEL_NAME_SQL,
                        (channel_id, channel.get("name"), channel.get("is_archived", False)),
                    )
            if counts.rows_in % NAME_COMMIT_EVERY == 0:
                conn.commit()
    print(f"channel names: {counts.rows_in} looked up, {counts.rows_rejected} unavailable")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        if "--name-unknown" in sys.argv:
            name_unknown(conn, bot_client())
        else:
            record_channel_names(conn, bot_client())


if __name__ == "__main__":
    main()
