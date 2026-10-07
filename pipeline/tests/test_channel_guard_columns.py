import re

from bot.nemo import channelguards
from lib.paths import MIGRATIONS_DIR

TABLE = "fd.channel_guard_events"


def migrated_columns():
    columns = []
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        sql = path.read_text()
        created = re.search(rf"CREATE TABLE {re.escape(TABLE)} \((.*?)\n\);", sql, re.S)
        if created:
            for line in created.group(1).splitlines():
                word = line.strip().split(" ")[0]
                if word and word.upper() != "CONSTRAINT":
                    columns.append(word)
        for statement in re.findall(rf"ALTER TABLE {re.escape(TABLE)}(.*?);", sql, re.S):
            for name in re.findall(r"ADD COLUMN (?:IF NOT EXISTS )?(\w+)", statement):
                columns.append(name)
            for name in re.findall(r"DROP COLUMN (?:IF EXISTS )?(\w+)", statement):
                columns.remove(name)
            for old, new in re.findall(r"RENAME COLUMN (\w+) TO (\w+)", statement):
                columns[columns.index(old)] = new
    return set(columns)


def test_enforcement_insert_names_only_columns_the_migrations_create():
    named = re.search(r"\((.*?)\)", channelguards.HAPPENED, re.S).group(1)
    inserted = {one.strip() for one in named.split(",")}
    assert inserted - migrated_columns() == set()
