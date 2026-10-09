import pathlib
import re

from lib import traits

MIGRATION = pathlib.Path(__file__).parents[2] / "db" / "migrations" / "0196_member_trait.sql"


def test_the_table_accepts_exactly_the_kinds_the_writers_know():
    sql = MIGRATION.read_text()
    listed = re.search(r"kind IN \((.*?)\)\)", sql, re.S).group(1)
    assert tuple(re.findall(r"'([a-z_0-9]+)'", listed)) == traits.KINDS


def test_who_else_shares_a_value_is_one_index_lookup():
    assert "ON fd.member_trait (kind, value)" in MIGRATION.read_text()


def test_a_member_holds_each_value_once():
    assert "PRIMARY KEY (user_id, kind, value)" in MIGRATION.read_text()
