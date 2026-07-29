import sys
from pathlib import Path

from dotenv import load_dotenv
from slack_sdk.errors import SlackApiError

from lib.db import connect, dead_letter, get_cursor, ingest_run, save_cursor
from lib.slack_client import admin_client, bot_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
SOURCE = "autojoin"

CHANNEL_NAME_SQL = """
INSERT INTO raw.channel_dim (channel_id, name, archived, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET
    name = EXCLUDED.name,
    archived = EXCLUDED.archived,
    updated_at = now()
"""


def resolve_team_id():
    for page in admin_client().admin_teams_list(limit=99):
        teams = page.get("teams", [])
        if teams:
            return teams[0]["id"]
    raise RuntimeError("admin.teams.list returned no teams")


def join_all(conn, client, join=True):
    team_id = resolve_team_id()
    with ingest_run(conn, SOURCE) as counts:
        cursor = get_cursor(conn, SOURCE)
        while True:
            page = client.conversations_list(
                types="public_channel", exclude_archived=True, limit=200, team_id=team_id, cursor=cursor
            )
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


def main():
    load_dotenv(ENV_FILE)
    join = "--no-join" not in sys.argv
    with connect() as conn:
        join_all(conn, bot_client(), join=join)


if __name__ == "__main__":
    main()
