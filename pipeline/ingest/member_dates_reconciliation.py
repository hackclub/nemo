from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.proxy_client import InternalApiError, InternalAuthError, ProxyClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "member_dates_reconciliation"

UPDATE_SQL = """
UPDATE raw.member_dim SET account_created_verified = %s, updated_at = now() WHERE user_id = %s
"""


def parse_epoch(value):
    if not value:
        return None
    return datetime.fromtimestamp(int(value), tz=timezone.utc)


def run(conn):
    with ingest_run(conn, SOURCE) as counts:
        client = ProxyClient()

        avail = client.call("admin.analytics.getAvailableDateRange", {"type": "member"})
        params = {
            "start_date": avail["start_date"],
            "end_date": avail["end_date"],
            "sort_column": "real_name",
            "sort_direction": "asc",
        }

        for i, member in enumerate(
            client.paginate(
                "admin.analytics.getMemberAnalytics",
                params,
                "member_activity",
                page_size=500,
                cursor_param="cursor_mark",
            )
        ):
            counts.rows_in += 1
            try:
                with conn.cursor() as cur:
                    cur.execute(UPDATE_SQL, (parse_epoch(member.get("date_created")), member["user_id"]))
            except (InternalApiError, KeyError) as exc:
                counts.rows_rejected += 1
                conn.rollback()
                dead_letter(conn, SOURCE, {"user_id": member.get("user_id")}, str(exc))

            if (i + 1) % 2000 == 0:
                conn.commit()
                print(f"{SOURCE}: {i + 1} processed")

        conn.commit()
    print(f"{SOURCE}: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        try:
            run(conn)
        except InternalAuthError as exc:
            print(f"{SOURCE}: auth error, aborting: {exc}")


if __name__ == "__main__":
    main()
