from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient

SOURCE = "admin_users"
METHOD = "admin.users.list"
PAGE_SIZE = 100

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


def write(conn, rows):
    with conn.cursor() as cur:
        cur.executemany(KNOWN_SQL, [(row[0],) for row in rows])
        cur.executemany(IDENTITY_SQL, rows)
    conn.commit()


def run(conn):
    client = ProxyClient()
    with ingest_run(conn, SOURCE) as counts:
        rows = []
        for user in client.paginate(
            METHOD, {}, "users",
            page_size=PAGE_SIZE, cursor_param="cursor", max_retries=8, credential="admin",
            page_param="limit", cursor_field="response_metadata.next_cursor",
        ):
            counts.rows_in += 1
            try:
                rows.append(identity_row(user))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, SOURCE, {"keys": sorted(user)}, str(exc))
                continue
            if len(rows) >= PAGE_SIZE:
                write(conn, rows)
                counts.progress()
                print(f"admin.users.list: {counts.rows_in} rows so far, {counts.rows_rejected} rejected")
                rows = []
        if rows:
            write(conn, rows)
    print(f"admin.users.list: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn)


if __name__ == "__main__":
    main()
