import os
import re

from seed import (
    SEED_CHANNEL_PREFIX,
    SEED_REF_PREFIX,
    SEED_SOURCE_PREFIX,
    SEED_USER_PREFIX,
)

ALLOWED_SUFFIX = re.compile(r"_(dev|test|seed)$")

FOREIGN_ROWS = [
    ("raw.member_dim", f"user_id NOT LIKE '{SEED_USER_PREFIX}%'"),
    ("raw.channel_dim", f"channel_id NOT LIKE '{SEED_CHANNEL_PREFIX}%'"),
    ("raw.member_message_history", f"user_id NOT LIKE '{SEED_USER_PREFIX}%'"),
    ("raw.member_first_reply", f"user_id NOT LIKE '{SEED_USER_PREFIX}%'"),
    ("raw.top_posters_snapshot", f"user_id NOT LIKE '{SEED_USER_PREFIX}%'"),
    ("raw.member_activity_snapshot", f"user_id NOT LIKE '{SEED_USER_PREFIX}%'"),
    ("raw.channel_activity_snapshot", f"channel_id NOT LIKE '{SEED_CHANNEL_PREFIX}%'"),
    ("raw.message_activity_snapshot", f"channel_id NOT LIKE '{SEED_CHANNEL_PREFIX}%'"),
    ("raw.team_stats_snapshot", f"source NOT LIKE '{SEED_SOURCE_PREFIX}%'"),
    ("raw.analytics_day", f"source NOT LIKE '{SEED_SOURCE_PREFIX}%'"),
    (
        "fd.cases",
        f"external_ref IS NULL OR external_ref NOT LIKE '{SEED_REF_PREFIX}%'",
    ),
    (
        "fd.case_reports",
        f"external_ref IS NULL OR external_ref NOT LIKE '{SEED_REF_PREFIX}%'",
    ),
]


class SeedRefused(RuntimeError):
    """The seeder will not write to this database"""


def target_allowed(dbname, allow=None):
    if not dbname:
        return False
    if allow and dbname == allow:
        return True
    return ALLOWED_SUFFIX.search(dbname) is not None


def check_target_name(dbname=None, allow=None):
    dbname = dbname if dbname is not None else os.environ.get("POSTGRES_DB", "")
    allow = allow if allow is not None else os.environ.get("SEED_ALLOW_DB", "").strip()
    if target_allowed(dbname, allow):
        return dbname
    raise SeedRefused(
        f"{dbname or 'POSTGRES_DB'} is not a seed target. name it with a _dev, _test or "
        f"_seed suffix, or set SEED_ALLOW_DB={dbname} if you are certain"
    )


def foreign_rows(conn):
    found = []
    for table, predicate in FOREIGN_ROWS:
        count = conn.execute(f"SELECT count(*) FROM {table} WHERE {predicate}").fetchone()[0]
        if count:
            found.append((table, count))
    return found


def check_no_real_data(conn, force=False):
    found = foreign_rows(conn)
    if not found:
        return found
    listed = ", ".join(f"{table} ({count} rows)" for table, count in found)
    if force:
        print(f"seed: --force, overwriting a database that holds rows the seeder did not write: {listed}")
        return found
    raise SeedRefused(
        f"this database holds rows the seeder did not write: {listed}. "
        "seeding would mix synthetic data into it. pass --force only if you are certain"
    )


def check(conn, force=False):
    dbname = check_target_name()
    mode = conn.execute("SELECT mode FROM raw.deployment").fetchone()[0]
    check_no_real_data(conn, force=force)
    return dbname, mode
