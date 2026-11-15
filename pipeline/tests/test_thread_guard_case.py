from bot.nemo import guards


class Conn:
    def __init__(self, rows=None):
        self.rows = rows or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        for mark, row in self.rows.items():
            if mark in self.executed[-1][0]:
                return row
        return None

    def args_for(self, mark):
        return [args for sql, args in self.executed if mark in sql]


def test_open_guard_thread_on_case_sets_case_id():
    conn = Conn({"FROM fd.case_threads": (412,), "INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough")
    assert conn.args_for("INSERT INTO fd.thread_guards")[0][6] == 412


def test_open_guard_thread_without_case_sets_case_id_none():
    conn = Conn({"INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough")
    assert conn.args_for("INSERT INTO fd.thread_guards")[0][6] is None


def test_open_guard_explicit_case_id_skips_case_thread_lookup():
    conn = Conn({"FROM fd.case_threads": (412,), "INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough", case_id=318)
    assert conn.args_for("INSERT INTO fd.thread_guards")[0][6] == 318
    assert conn.args_for("FROM fd.case_threads") == []


def test_on_a_case_sql_prefers_primary_thread():
    assert "is_primary DESC" in guards.ON_A_CASE


def test_on_a_case_sql_skips_removed_threads():
    assert "removed_at IS NULL" in guards.ON_A_CASE


def test_open_guard_audit_row_includes_case_id():
    conn = Conn({"FROM fd.case_threads": (412,), "INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough")
    recorded = conn.args_for("INSERT INTO fd.audit")[0]
    assert recorded[6].obj["case_id"] == 412
