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


class TunedConn(EmptyConn):
    def __init__(self, rows):
        super().__init__()
        self.rows = rows

    def fetchall(self):
        return self.rows


def test_reclaim_runs_on_the_file_default_when_nothing_is_set():
    assert settings.reclaim_seconds(EmptyConn()) == 900


def test_reclaim_honours_what_the_engine_asked_for():
    asked = TunedConn([("engine", "reclaim_seconds", "1800")])
    assert settings.reclaim_seconds(asked) == 1800

    low = TunedConn([("engine", "reclaim_seconds", "30")])
    assert settings.reclaim_seconds(low) == settings.RECLAIM_FLOOR_SECONDS

    blank = TunedConn([("engine", "reclaim_seconds", "")])
    assert settings.reclaim_seconds(blank) == 900


def test_reclaim_is_only_off_when_the_engine_says_off():
    off = TunedConn([("engine", "reclaim_seconds", settings.OFF)])
    assert settings.reclaim_seconds(off) is None


def test_reclaim_still_runs_when_the_settings_table_is_unreadable(monkeypatch):
    monkeypatch.setattr(settings, "_warned", False)
    assert settings.reclaim_seconds(BrokenConn()) == 900


def test_the_unreadable_warning_prints_once(monkeypatch, capsys):
    monkeypatch.setattr(settings, "_warned", False)
    conn = BrokenConn()
    settings.tuned(conn)
    settings.tuned(conn)
    out = capsys.readouterr().out
    assert out.count("app.engine_setting is unreadable") == 1
