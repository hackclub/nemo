import os
from datetime import datetime, timezone

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

MEMBER_SQL = """
INSERT INTO fd.member (
    user_id, handle, display_name, avatar_url, avatar_hash,
    is_bot, is_deleted, profile_updated_at, synced_at
)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    handle = EXCLUDED.handle,
    display_name = EXCLUDED.display_name,
    avatar_url = EXCLUDED.avatar_url,
    avatar_hash = EXCLUDED.avatar_hash,
    is_bot = EXCLUDED.is_bot,
    is_deleted = EXCLUDED.is_deleted,
    profile_updated_at = EXCLUDED.profile_updated_at,
    synced_at = now()
"""

IDENTITY_NAME_SQL = """
INSERT INTO fd.member_identity (user_id, first_name, last_name, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    first_name = EXCLUDED.first_name,
    last_name = EXCLUDED.last_name,
    updated_at = now()
WHERE fd.member_identity.purged_at IS NULL
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


def profile_of(user):
    return user.get("profile") or {}


def member_row(user):
    profile = profile_of(user)
    updated = user.get("updated")
    return (
        user["id"],
        user.get("name") or None,
        profile.get("display_name") or profile.get("real_name") or None,
        profile.get("image_512") or None,
        profile.get("avatar_hash") or None,
        bool(user.get("is_bot")),
        bool(user.get("deleted")),
        datetime.fromtimestamp(updated, tz=timezone.utc) if updated else None,
    )


def identity_name_row(user):
    profile = profile_of(user)
    first = profile.get("first_name") or None
    last = profile.get("last_name") or None
    if first is None and last is None:
        return None
    return (user["id"], first, last)


def run(conn):
    team = team_id()
    with ingest_run(conn, SOURCE) as counts:
        cursor = get_cursor(conn, SOURCE) or ""
        client = bot_client()
        while True:
            page = client.users_list(team_id=team, limit=PAGE_SIZE, cursor=cursor)
            dim_rows = []
            member_rows = []
            name_rows = []
            for user in page.get("members", []):
                counts.rows_in += 1
                try:
                    dim_rows.append(member_dim_row(user))
                    member_rows.append(member_row(user))
                    name = identity_name_row(user)
                except KeyError as exc:
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, {"keys": sorted(user)}, str(exc))
                    continue
                if name:
                    name_rows.append(name)
            with conn.cursor() as cur:
                cur.executemany(MEMBER_DIM_SQL, dim_rows)
                cur.executemany(MEMBER_SQL, member_rows)
                cur.executemany(IDENTITY_NAME_SQL, name_rows)
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
