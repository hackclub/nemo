from pathlib import Path

from dotenv import load_dotenv
from slack_sdk.errors import SlackApiError

from lib.db import connect, dead_letter, finish_run, start_run
from lib.slack_client import admin_client, bot_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
SOURCE = "autojoin"


def resolve_team_id():
    for page in admin_client().admin_teams_list(limit=99):
        teams = page.get("teams", [])
        if teams:
            return teams[0]["id"]
    raise RuntimeError("admin.teams.list returned no teams")


def list_public_channel_ids(client, team_id):
    for page in client.conversations_list(
        types="public_channel", exclude_archived=True, limit=200, team_id=team_id
    ):
        for channel in page.get("channels", []):
            yield channel["id"]


def join_all(conn, client):
    team_id = resolve_team_id()
    run_id = start_run(conn, SOURCE)
    rows_in = rows_rejected = 0
    for channel_id in list_public_channel_ids(client, team_id):
        rows_in += 1
        try:
            client.conversations_join(channel=channel_id)
        except SlackApiError as exc:
            error = exc.response.get("error")
            if error == "is_archived":
                continue
            rows_rejected += 1
            dead_letter(conn, SOURCE, {"channel_id": channel_id}, error or str(exc))
    finish_run(conn, run_id, "ok", rows_in, rows_rejected)
    conn.commit()
    print(f"autojoin: {rows_in} channels checked, {rows_rejected} failed")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        join_all(conn, bot_client())


if __name__ == "__main__":
    main()
