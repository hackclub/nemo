import hashlib

from dotenv import load_dotenv

from lib.db import connect_admin
from lib.paths import ENV_FILE, MIGRATIONS_DIR

SCHEMAS = ("raw", "analytics", "app", "fd", "ingest")
BASELINE_WITNESS = "raw.member_dim"

VERSION_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS raw.schema_version (
    filename text PRIMARY KEY,
    checksum text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
)
"""


def migrations():
    return sorted(MIGRATIONS_DIR.glob("*.sql"))


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def applied(conn):
    return {
        row[0]: row[1]
        for row in conn.execute("SELECT filename, checksum FROM raw.schema_version")
    }


def witness_exists(conn):
    return bool(
        conn.execute("SELECT to_regclass(%s)", (BASELINE_WITNESS,)).fetchone()[0]
    )


def stamp(conn, path):
    conn.execute(
        "INSERT INTO raw.schema_version (filename, checksum) VALUES (%s, %s) "
        "ON CONFLICT (filename) DO NOTHING",
        (path.name, checksum(path)),
    )


def baseline(conn, files):
    for path in files:
        stamp(conn, path)
    conn.commit()
    print(
        f"migrate: {BASELINE_WITNESS} already exists, so this database predates version "
        f"tracking. stamped {len(files)} migration(s) as applied without running them"
    )


def apply(conn, path):
    conn.execute(path.read_text())
    stamp(conn, path)
    conn.commit()
    print(f"migrate: applied {path.name}")


def main() -> None:
    load_dotenv(ENV_FILE)
    files = migrations()
    with connect_admin() as conn:
        for schema in SCHEMAS:
            conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        conn.execute(VERSION_TABLE_SQL)
        conn.commit()

        seen = applied(conn)
        if not seen and witness_exists(conn):
            baseline(conn, files)
            return

        for path in files:
            if path.name in seen:
                if seen[path.name] != checksum(path):
                    raise SystemExit(
                        f"migrate: {path.name} changed after it was applied. migrations are "
                        f"immutable once applied, add a new file instead"
                    )
                continue
            apply(conn, path)

    pending = [p.name for p in files if p.name not in seen]
    if not pending:
        print(f"migrate: up to date, {len(files)} migration(s) applied")


if __name__ == "__main__":
    main()
