import os
import sys

from dotenv import load_dotenv
from slack_sdk.errors import SlackApiError

from lib.channel_dim import PRIVATE, UPSERT as CHANNEL_NAME_SQL, visibility_of
from lib.db import connect, get_cursor, ingest_run, save_cursor
from lib.paths import ENV_FILE
from lib.slack_client import bot_client
from lib.task import per_entity

SOURCE = "channel_roster"
NAME_SOURCE = "channel_info_names"
NAME_COMMIT_EVERY = 100
LISTED_TYPES = "public_channel,private_channel"
TEAM_ERRORS = ("team_not_found", "team_access_not_granted", "invalid_team_id")
UNREACHABLE_ERRORS = (
    "channel_not_found",
    "team_access_not_granted",
    "method_not_supported_for_channel_type",
)

MARK_UNREACHABLE_SQL = """
UPDATE raw.channel_dim SET name_unavailable = true, updated_at = now() WHERE channel_id = %s
"""


def resolve_team_id():
    configured = os.environ.get("SLACK_TEAM_ID", "").strip()
    if not configured:
        raise RuntimeError("SLACK_TEAM_ID must be set to the workspace the channel roster lists")
    return configured


def list_channels(client, team_id, cursor):
    try:
        return client.conversations_list(
            types=LISTED_TYPES, exclude_archived=False, limit=200,
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
        archived = 0
        private = 0
        while True:
            page = list_channels(client, team_id, cursor)
            for channel in page.get("channels", []):
                counts.rows_in += 1
                is_archived = bool(channel.get("is_archived", False))
                archived += is_archived
                seen = visibility_of(channel)
                private += seen == PRIVATE
                with conn.cursor() as cur:
                    cur.execute(
                        CHANNEL_NAME_SQL,
                        (channel["id"], channel.get("name"), is_archived, seen),
                    )
            cursor = page.get("response_metadata", {}).get("next_cursor") or ""
            save_cursor(conn, SOURCE, cursor)
            conn.commit()
            if not cursor:
                break
    print(f"{SOURCE}: {counts.rows_in} channels named, {private} private, {archived} archived, "
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
                        (channel_id, channel.get("name"), channel.get("is_archived", False),
                         visibility_of(channel)),
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
