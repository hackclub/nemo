import psycopg
import pytest

from jobs import migrate


class FakePath:
    name = "0099_test.sql"

    def read_text(self):
        return "ALTER TABLE raw.ingest_run ADD COLUMN x int"

    def read_bytes(self):
        return b"ALTER TABLE raw.ingest_run ADD COLUMN x int"


class LockedThenFree:
    def __init__(self, locked_for):
        self.locked_for = locked_for
        self.executed = []
        self.rollbacks = 0
        self.commits = 0

    def execute(self, sql, params=None):
        self.executed.append(sql)
        if sql.startswith("ALTER") and len([s for s in self.executed if s.startswith("ALTER")]) <= self.locked_for:
            raise psycopg.errors.LockNotAvailable("canceling statement due to lock timeout")
        return self

    def rollback(self):
        self.rollbacks += 1

    def commit(self):
        self.commits += 1


def test_a_migration_that_finds_its_lock_on_the_second_try_applies(monkeypatch):
    monkeypatch.setattr(migrate.time, "sleep", lambda s: None)
    conn = LockedThenFree(locked_for=1)
    migrate.apply(conn, FakePath(), attempts=3, wait=0)
    assert conn.rollbacks == 1
    assert conn.commits == 1
    assert any("schema_version" in s for s in conn.executed)


def test_a_migration_that_never_gets_its_lock_exits_by_name(monkeypatch):
    monkeypatch.setattr(migrate.time, "sleep", lambda s: None)
    conn = LockedThenFree(locked_for=99)
    with pytest.raises(SystemExit) as caught:
        migrate.apply(conn, FakePath(), attempts=3, wait=0)
    assert "0099_test.sql" in str(caught.value)
    assert "3 attempts" in str(caught.value)
    assert conn.rollbacks == 3
    assert conn.commits == 0


def test_a_migration_with_no_lock_trouble_applies_once():
    conn = LockedThenFree(locked_for=0)
    migrate.apply(conn, FakePath())
    assert conn.rollbacks == 0
    assert conn.commits == 1
