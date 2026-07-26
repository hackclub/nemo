from pathlib import Path

from dotenv import load_dotenv
from slack_sdk.errors import SlackApiError

from lib.db import connect, dead_letter, finish_run, start_run
from lib.slack_client import bot_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "claimed_reconciliation"

CANDIDATES_SQL = """
SELECT user_id FROM raw.member_dim
WHERE deactivated_at IS NOT NULL AND claimed_at IS NULL AND claimed_no_date IS NULL
"""

UPDATE_SQL = """
UPDATE raw.member_dim SET claimed_no_date = %s, updated_at = now() WHERE user_id = %s
"""


def was_ever_claimed(client, user_id):
    resp = client.users_info(user=user_id)
    return "is_invited_user" not in resp["user"]


def run(conn):
    run_id = start_run(conn, SOURCE)
    rows_in = rows_rejected = 0
    client = bot_client()

    with conn.cursor() as cur:
        cur.execute(CANDIDATES_SQL)
        user_ids = [row[0] for row in cur.fetchall()]

    for i, user_id in enumerate(user_ids):
        rows_in += 1
        try:
            claimed_no_date = was_ever_claimed(client, user_id)
            with conn.cursor() as cur:
                cur.execute(UPDATE_SQL, (claimed_no_date, user_id))
        except (SlackApiError, OSError, TimeoutError) as exc:
            rows_rejected += 1
            conn.rollback()
            dead_letter(conn, SOURCE, {"user_id": user_id}, str(exc))

        if (i + 1) % 200 == 0:
            conn.commit()
            print(f"{SOURCE}: {i + 1}/{len(user_ids)}")

    conn.commit()
    finish_run(conn, run_id, "ok", rows_in, rows_rejected)
    conn.commit()
    print(f"{SOURCE}: {rows_in} rows, {rows_rejected} rejected")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn)


if __name__ == "__main__":
    main()
