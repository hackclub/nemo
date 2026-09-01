import argparse

from dotenv import load_dotenv

from lib.db import connect, ingest_run
from lib.paths import ENV_FILE

SOURCE = "dim_snapshot"

MEMBER_SQL = """
INSERT INTO raw.member_dim_snapshot
    (user_id, observed_on, record_hash, account_created, account_created_verified,
     claimed_at, deactivated_at, is_bot, is_admin, is_owner, is_primary_owner,
     is_restricted, is_ultra_restricted, is_invited_member, is_invited_guest,
     is_deleted, invite_pending)
SELECT
    user_id, current_date,
    md5(concat_ws('|', is_bot, is_admin, is_owner, is_primary_owner, is_restricted,
        is_ultra_restricted, is_invited_member, is_invited_guest, is_deleted,
        invite_pending, deactivated_at, claimed_at)),
    account_created, account_created_verified, claimed_at, deactivated_at,
    is_bot, is_admin, is_owner, is_primary_owner, is_restricted, is_ultra_restricted,
    is_invited_member, is_invited_guest, is_deleted, invite_pending
FROM raw.member_dim
ON CONFLICT (user_id, observed_on) DO UPDATE SET
    record_hash = EXCLUDED.record_hash,
    deactivated_at = EXCLUDED.deactivated_at,
    is_admin = EXCLUDED.is_admin,
    is_deleted = EXCLUDED.is_deleted,
    observed_at = now()
"""

CHANNEL_SQL = """
INSERT INTO raw.channel_dim_snapshot
    (channel_id, observed_on, record_hash, name, visibility, archived, date_created)
SELECT
    channel_id, current_date,
    md5(concat_ws('|', name, visibility, archived)),
    name, visibility, archived, date_created
FROM raw.channel_dim
ON CONFLICT (channel_id, observed_on) DO UPDATE SET
    record_hash = EXCLUDED.record_hash,
    name = EXCLUDED.name,
    archived = EXCLUDED.archived,
    observed_at = now()
"""


def run(conn):
    with ingest_run(conn, SOURCE) as counts:
        with conn.cursor() as cur:
            cur.execute(MEMBER_SQL)
            members = cur.rowcount
            cur.execute(CHANNEL_SQL)
            channels = cur.rowcount
        conn.commit()
        counts.rows_in = members + channels
    print(f"{SOURCE}: {members} member and {channels} channel snapshot row(s) for today")
    return members + channels


def main():
    argparse.ArgumentParser().parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn)


if __name__ == "__main__":
    main()
