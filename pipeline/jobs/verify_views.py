import re
import sys

from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE, WEB_DIR

TABLE_NAME = re.compile(r'self\.table_name\s*=\s*"((?:analytics|ingest)\.[a-z0-9_]+)"')
MODELS = WEB_DIR / "app" / "models"
EXISTS_SQL = """
SELECT 1 FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = %s AND c.relname = %s
"""


def declared_relations(texts):
    return sorted({match.group(1) for text in texts for match in TABLE_NAME.finditer(text)})


def rails_relations():
    return declared_relations(path.read_text() for path in MODELS.rglob("*.rb"))


def missing(conn, relations):
    gone = []
    for relation in relations:
        schema, name = relation.split(".", 1)
        if conn.execute(EXISTS_SQL, (schema, name)).fetchone() is None:
            gone.append(relation)
    return gone


def main():
    load_dotenv(ENV_FILE)
    relations = rails_relations()
    with connect() as conn:
        gone = missing(conn, relations)
    if gone:
        print(f"verify_views: {len(gone)} relation(s) Rails reads do not exist: " + ", ".join(gone))
        return 1
    print(f"verify_views: all {len(relations)} relation(s) Rails reads exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
