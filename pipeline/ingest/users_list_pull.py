import os

from dotenv import load_dotenv

from lib.db import connect, dead_letter, get_cursor, ingest_run, save_cursor
from lib.paths import ENV_FILE
from lib.slack_client import bot_client

SOURCE = "users_list"
PAGE_SIZE = 200

MEMBER_DIM_SQL = """
INSERT INTO raw.member_dim (
    user_id, is_deleted, is_bot, is_admin, is_owner, is_primary_owner,
    is_restricted, is_ultra_restricted, invite_pending, updated_at
)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    is_deleted = EXCLUDED.is_deleted,
    invite_pending = EXCLUDED.invite_pending,
    is_bot = EXCLUDED.is_bot,
    is_admin = EXCLUDED.is_admin,
    is_owner = EXCLUDED.is_owner,
    is_primary_owner = EXCLUDED.is_primary_owner,
    is_restricted = EXCLUDED.is_restricted,
    is_ultra_restricted = EXCLUDED.is_ultra_restricted,
    updated_at = now()
"""

def team_id():
    value = os.environ.get("SLACK_TEAM_ID", "").strip()
    if not value:
        raise RuntimeError("SLACK_TEAM_ID must be set to the workspace users.list is read from")
    return value


def member_dim_row(user):
    return (
        user["id"],
        bool(user.get("deleted")),
        bool(user.get("is_bot")),
        bool(user.get("is_admin")),
        bool(user.get("is_owner")),
        bool(user.get("is_primary_owner")),
        bool(user.get("is_restricted")),
        bool(user.get("is_ultra_restricted")),
        "is_invited_user" in user,
    )


def run(conn):
    team = team_id()
    with ingest_run(conn, SOURCE) as counts:
        cursor = get_cursor(conn, SOURCE) or ""
        client = bot_client()
        while True:
            page = client.users_list(team_id=team, limit=PAGE_SIZE, cursor=cursor)
            dim_rows = []
            for user in page.get("members", []):
                counts.rows_in += 1
                try:
                    dim_rows.append(member_dim_row(user))
                except KeyError as exc:
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, {"keys": sorted(user)}, str(exc))
            with conn.cursor() as cur:
                cur.executemany(MEMBER_DIM_SQL, dim_rows)
            cursor = page.get("response_metadata", {}).get("next_cursor") or ""
            save_cursor(conn, SOURCE, cursor)
            conn.commit()
            counts.progress()
            if not cursor:
                break
    print(f"users.list: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn)


if __name__ == "__main__":
    main()
