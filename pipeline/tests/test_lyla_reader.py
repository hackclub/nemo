import datetime as dt

from lyla import reader

AT = dt.datetime(2026, 10, 22, 9, tzinfo=dt.UTC)
AT_MS = int(AT.timestamp() * 1000)


class Recorder:
    def __init__(self, answers=None):
        self.answers = answers or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return Rows(self.answers.get(sql, []))

    def ran(self, sql):
        return [args for statement, args in self.executed if statement == sql]


class Rows:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


def lyla_case(status, resolved_by="UFF1", merged_into=None, resolved_ms=AT_MS):
    return (5002, status, AT_MS - 1000, resolved_ms, resolved_by, status, merged_into)


def nemo_case(resolved_at=None, resolution=None, duplicate_of=None):
    return (5002, resolved_at, resolution, duplicate_of, AT - dt.timedelta(days=1))


def test_sync_status_resolved_in_lyla_closes_the_nemo_case_and_its_reports():
    conn = Recorder({reader.LIVE_ACTION_COUNT: [(2,)]})
    assert reader.Reader(None, None).sync_status(conn, lyla_case("resolved"), nemo_case())
    assert conn.ran(reader.RESOLVE) == [(AT, "action_taken", None, 5002)]
    assert conn.ran(reader.CLOSE_REPORTS) == [(AT, "UFF1", 5002)]


def test_sync_status_canceled_in_lyla_closes_as_not_conduct():
    conn = Recorder({reader.LIVE_ACTION_COUNT: [(0,)]})
    reader.Reader(None, None).sync_status(conn, lyla_case("canceled"), nemo_case())
    assert conn.ran(reader.RESOLVE)[0][1] == "not_conduct"


def test_sync_status_expired_in_lyla_leaves_nemo_alone():
    conn = Recorder()
    assert reader.Reader(None, None).sync_status(conn, lyla_case("expired"), nemo_case())
    assert conn.executed == []


def test_sync_status_reopened_in_lyla_reopens_case_and_reports():
    conn = Recorder()
    reader.Reader(None, None).sync_status(conn, lyla_case("open", resolved_by=None, resolved_ms=None),
                                          nemo_case(AT, "no_action"))
    assert conn.ran(reader.REOPEN) == [(5002,)]
    assert conn.ran(reader.REOPEN_REPORTS) == [(5002,)]


def test_sync_status_merged_in_lyla_marks_duplicate_of_the_target():
    conn = Recorder({reader.EXISTING_CASES: [(5005,)], reader.LIVE_ACTION_COUNT: [(0,)]})
    reader.Reader(None, None).sync_status(conn, lyla_case("merged", merged_into=5005, resolved_ms=None),
                                          nemo_case())
    assert conn.ran(reader.RESOLVE)[0][1:] == ("duplicate", 5005, 5002)


def test_sync_status_same_status_puts_nemos_resolver_back(monkeypatch):
    calls = []
    monkeypatch.setattr(reader.writer, "set_resolver", lambda lyla, *args: calls.append(args))
    lyla = Recorder()
    lyla.commit = lambda: None
    conn = Recorder({reader.RESOLVER: [("UFF1",)]})
    reader.Reader(None, lyla).sync_status(conn, lyla_case("resolved", resolved_by="UNEMOBOT"),
                                          nemo_case(AT, "action_taken"))
    assert calls == [(5002, "UFF1", AT)]
    assert conn.ran(reader.RESOLVE) == []


def test_sync_status_same_status_and_resolver_changes_nothing(monkeypatch):
    monkeypatch.setattr(reader.writer, "set_resolver", lambda *args: (_ for _ in ()).throw(AssertionError))
    conn = Recorder({reader.RESOLVER: [("UFF1",)]})
    reader.Reader(None, None).sync_status(conn, lyla_case("resolved"), nemo_case(AT, "no_action"))
    assert conn.ran(reader.RESOLVE) == []


def test_merges_root_walks_up_to_the_main_case():
    from bot.core import merges

    class RootConn:
        def __init__(self):
            self.executed = []

        def execute(self, sql, args=None):
            self.executed.append((sql, args))
            return self

        def fetchone(self):
            return (19,)

    conn = RootConn()

    assert merges.root(conn, 25) == 19
    assert conn.executed == [(merges.ROOT, (25,))]


class Names:
    def key_for(self, code):
        return "spam"


def lyla_action(action_type):
    return {"id": 4321, "action_type": action_type, "data": {"whatTheyDid": "spam"}, "target_user_id": "U1",
            "performed_by": ["UFF1"], "performed_at": AT_MS, "category_code": 11, "category_extra": None}


def test_import_of_a_combined_lyla_action_groups_its_types():
    conn = Recorder({reader.INSERT_ACTION: [(9001,)]})
    sync = reader.Reader(None, None)
    sync.categories = Names()

    sync.import_action(conn, 5002, lyla_action("Warning, DM"))

    assert [args[1] for args in conn.ran(reader.INSERT_ACTION)] == ["warning", "dm"]
    assert conn.ran(reader.GROUP_IMPORTED) == [{"prefix": "lyla:action:4321:%"}]


def test_import_of_a_single_type_lyla_action_is_not_grouped():
    conn = Recorder({reader.INSERT_ACTION: [(9001,)]})
    sync = reader.Reader(None, None)
    sync.categories = Names()

    sync.import_action(conn, 5002, lyla_action("Warning"))

    assert conn.ran(reader.GROUP_IMPORTED) == []


def reversing(monkeypatch, type_key, running=()):
    calls = []
    monkeypatch.setattr(reader.reactivation, "running_bans", lambda conn, user_id: list(running))
    monkeypatch.setattr(reader.reactivation, "reactivate",
                        lambda conn, user_id, by, why, end_bans=True: calls.append((user_id, by, why, end_bans))
                        or ("queued", []))
    monkeypatch.setattr(reader.store, "record", lambda *args, **kwargs: None)
    conn = Recorder({reader.REVERSE_ACTION: [(9001, type_key, "U1")]})
    sync = reader.Reader(None, None)
    sync.reverse(conn, 9001, AT, "Reversed in LYLA")
    return sync, calls


def test_a_ban_reversed_in_lyla_reactivates_the_account(monkeypatch):
    sync, calls = reversing(monkeypatch, "indef_ban")

    assert calls == [("U1", reader.LYLA_BOT_USER_ID, "Reversed in LYLA", False)]
    assert sync.summary["reactivated"] == 1


def test_a_reversed_ban_leaves_the_account_alone_while_another_ban_runs(monkeypatch):
    _sync, calls = reversing(monkeypatch, "perma_ban", running=[(77, None)])

    assert calls == []


def test_a_reversed_warning_does_not_reactivate(monkeypatch):
    _sync, calls = reversing(monkeypatch, "warning")

    assert calls == []
