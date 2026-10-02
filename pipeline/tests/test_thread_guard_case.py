from bot.nemo import guards


class Conn:
    def __init__(self, rows=None):
        self.rows = rows or {}
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        for mark, row in self.rows.items():
            if mark in self.ran[-1][0]:
                return row
        return None

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


def test_a_thread_already_on_a_case_opens_its_guard_against_that_case():
    conn = Conn({"FROM fd.case_threads": (412,), "INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough")
    assert conn.did("INSERT INTO fd.thread_guards")[0][6] == 412


def test_a_thread_on_no_case_opens_a_guard_that_names_none():
    conn = Conn({"INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough")
    assert conn.did("INSERT INTO fd.thread_guards")[0][6] is None


def test_a_case_given_by_hand_is_not_second_guessed():
    conn = Conn({"FROM fd.case_threads": (412,), "INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough", case_id=318)
    assert conn.did("INSERT INTO fd.thread_guards")[0][6] == 318
    assert conn.did("FROM fd.case_threads") == []


def test_the_primary_thread_wins_when_a_thread_is_on_more_than_one():
    assert "is_primary DESC" in guards.ON_A_CASE


def test_opening_is_written_down_against_the_case_it_found():
    conn = Conn({"FROM fd.case_threads": (412,), "INSERT INTO fd.thread_guards": (9,)})
    guards.open_guard(conn, guards.LOCK, "C1", "100.000", "UMOD", "enough")
    told = conn.did("INSERT INTO fd.audit")[0]
    assert told[6].obj["case_id"] == 412
