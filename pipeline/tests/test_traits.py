import pathlib
import re

from lib import traits

MIGRATIONS = pathlib.Path(__file__).parents[2] / "db" / "migrations"
MIGRATION = MIGRATIONS / "0196_member_trait.sql"
IDENTITY = MIGRATIONS / "0197_member_trait_identity.sql"
LOGINS = MIGRATIONS / "0198_member_trait_logins.sql"


def test_the_table_accepts_exactly_the_kinds_the_writers_know():
    sql = IDENTITY.read_text()
    listed = re.search(r"kind IN \((.*?)\)\)", sql, re.S).group(1)
    assert tuple(re.findall(r"'([a-z_0-9]+)'", listed)) == traits.KINDS


def test_who_else_shares_a_value_is_one_index_lookup():
    assert "ON fd.member_trait (kind, value)" in MIGRATION.read_text()


def test_a_member_holds_each_value_once():
    assert "PRIMARY KEY (user_id, kind, value)" in MIGRATION.read_text()


def test_every_writer_of_identity_and_names_keeps_its_traits_in_the_same_transaction():
    sql = IDENTITY.read_text()
    for table, columns in (("fd.member_identity", "email, real_name"), ("fd.member", "display_name, handle")):
        assert f"AFTER INSERT ON {table}" in sql
        assert f"AFTER UPDATE OF {columns} ON {table}" in sql
        assert f"AFTER DELETE ON {table}" in sql


def test_only_events_the_finder_reads_fire_the_audit_trigger():
    assert "WHEN (NEW.action IN ('anomaly', 'user_created'))" in IDENTITY.read_text()


def test_a_login_row_adds_only_the_sightings_it_gained():
    sql = LOGINS.read_text()
    assert "NEW.hits - CASE WHEN TG_OP = 'UPDATE' THEN OLD.hits ELSE 0 END" in sql
    assert "seen = held.seen + EXCLUDED.seen" in sql


def test_the_backfill_groups_addresses_the_way_the_finder_does():
    sql = LOGINS.read_text()
    assert "GROUP BY user_id, host(ip)" in sql and "GROUP BY user_id, host(ip_prefix)" in sql
