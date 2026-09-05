import psycopg

from lib import settings


class BrokenConn:
    def __init__(self):
        self.rollbacks = 0

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql):
        raise psycopg.errors.InsufficientPrivilege("permission denied for table engine_setting")

    def rollback(self):
        self.rollbacks += 1


class EmptyConn(BrokenConn):
    def execute(self, sql):
        return self

    def fetchall(self):
        return []


def test_an_unreadable_settings_table_is_a_sentinel_not_an_empty_dict(monkeypatch):
    monkeypatch.setattr(settings, "_warned", False)
    conn = BrokenConn()
    assert settings.tuned(conn) is settings.UNREADABLE
    assert conn.rollbacks == 1


def test_an_empty_settings_table_is_a_real_empty_dict():
    assert settings.tuned(EmptyConn()) == {}


def test_said_falls_back_when_unreadable_and_when_missing(monkeypatch):
    monkeypatch.setattr(settings, "_warned", False)
    assert settings.said(BrokenConn(), "member_days", "batch", "6") == "6"
    assert settings.said(EmptyConn(), "member_days", "batch", "6") == "6"


def test_the_unreadable_warning_prints_once(monkeypatch, capsys):
    monkeypatch.setattr(settings, "_warned", False)
    conn = BrokenConn()
    settings.tuned(conn)
    settings.tuned(conn)
    out = capsys.readouterr().out
    assert out.count("app.engine_setting is unreadable") == 1
