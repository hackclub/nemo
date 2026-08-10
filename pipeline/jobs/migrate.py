from dotenv import load_dotenv

from lib.db import connect_admin
from lib.paths import ENV_FILE, SQL_DIR

SCHEMAS = ("raw", "analytics", "app")


def main() -> None:
    load_dotenv(ENV_FILE)
    with connect_admin() as conn:
        for schema in SCHEMAS:
            conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        conn.commit()
        for path in sorted(SQL_DIR.glob("*.sql")):
            for statement in path.read_text().split(";"):
                stmt = statement.strip()
                if stmt:
                    conn.execute(stmt)


if __name__ == "__main__":
    main()
