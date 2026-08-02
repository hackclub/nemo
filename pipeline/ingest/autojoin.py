import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from slack_sdk.errors import SlackApiError

from lib.db import connect, dead_letter, get_cursor, ingest_run, save_cursor
from lib.slack_client import bot_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
SOURCE = "autojoin"
NAME_SOURCE = "channel_info_names"
TEAM_ERRORS = ("team_not_found", "team_access_not_granted", "invalid_team_id")

CHANNEL_NAME_SQL = """
INSERT INTO raw.channel_dim (channel_id, name, archived, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET
    name = EXCLUDED.name,
    archived = EXCLUDED.archived,
    updated_at = now()
"""


def resolve_team_id():
    configured = os.environ.get("SLACK_TEAM_ID", "").strip()
    if not configured:
        raise RuntimeError("SLACK_TEAM_ID must be set to the workspace autojoin scans")
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


def join_all(conn, client, join=True):
    team_id = resolve_team_id()
    with ingest_run(conn, SOURCE) as counts:
        cursor = get_cursor(conn, SOURCE)
        while True:
            page = list_public_channels(client, team_id, cursor)
            for channel in page.get("channels", []):
                counts.rows_in += 1
                with conn.cursor() as cur:
                    cur.execute(CHANNEL_NAME_SQL, (channel["id"], channel.get("name"), channel.get("is_archived", False)))
                if not join:
                    continue
                try:
                    client.conversations_join(channel=channel["id"])
                except SlackApiError as exc:
                    error = exc.response.get("error")
                    if error == "is_archived":
                        continue
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, {"channel_id": channel["id"]}, error or str(exc))
            cursor = page.get("response_metadata", {}).get("next_cursor") or ""
            save_cursor(conn, SOURCE, cursor)
            conn.commit()
            if not cursor:
                break
    verb = "checked" if join else "named (no join)"
    print(f"autojoin: {counts.rows_in} channels {verb}, {counts.rows_rejected} failed")


def name_unknown(conn, client):
    with conn.cursor() as cur:
        cur.execute("SELECT channel_id FROM raw.channel_dim WHERE name IS NULL")
        pending = [row[0] for row in cur.fetchall()]

    with ingest_run(conn, NAME_SOURCE) as counts:
        for channel_id in pending:
            counts.rows_in += 1
            try:
                channel = client.conversations_info(channel=channel_id)["channel"]
            except SlackApiError as exc:
                counts.rows_rejected += 1
                dead_letter(
                    conn, NAME_SOURCE, {"channel_id": channel_id},
                    exc.response.get("error") or str(exc),
                )
                continue
            with conn.cursor() as cur:
                cur.execute(
                    CHANNEL_NAME_SQL,
                    (channel_id, channel.get("name"), channel.get("is_archived", False)),
                )
    print(f"channel names: {counts.rows_in} looked up, {counts.rows_rejected} unavailable")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        if "--name-unknown" in sys.argv:
            name_unknown(conn, bot_client())
        else:
            join_all(conn, bot_client(), join="--no-join" not in sys.argv)


if __name__ == "__main__":
    main()
