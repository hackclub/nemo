from dotenv import load_dotenv

from lib.db import connect, dead_letter, get_cursor, ingest_run, save_cursor
from lib.paths import ENV_FILE
from lib.slack_client import admin_client

SOURCE = "admin_users"
PAGE_SIZE = 200

KNOWN_SQL = """
INSERT INTO fd.member (user_id) VALUES (%s) ON CONFLICT (user_id) DO NOTHING
"""

IDENTITY_SQL = """
INSERT INTO fd.member_identity (user_id, real_name, email, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    real_name = EXCLUDED.real_name,
    email = EXCLUDED.email,
    updated_at = now()
WHERE fd.member_identity.purged_at IS NULL
"""


def identity_row(user):
    return (
        user["id"],
        user.get("full_name") or None,
        user.get("email") or None,
    )


def run(conn):
    client = admin_client()
    with ingest_run(conn, SOURCE) as counts:
        cursor = get_cursor(conn, SOURCE) or ""
        while True:
            page = client.admin_users_list(limit=PAGE_SIZE, cursor=cursor)
            rows = []
            for user in page.get("users", []):
                counts.rows_in += 1
                try:
                    rows.append(identity_row(user))
                except KeyError as exc:
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, {"keys": sorted(user)}, str(exc))
            with conn.cursor() as cur:
                cur.executemany(KNOWN_SQL, [(row[0],) for row in rows])
                cur.executemany(IDENTITY_SQL, rows)
            cursor = page.get("response_metadata", {}).get("next_cursor") or ""
            save_cursor(conn, SOURCE, cursor)
            conn.commit()
            counts.progress()
            if not cursor:
                break
    print(f"admin.users.list: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn)


if __name__ == "__main__":
    main()
