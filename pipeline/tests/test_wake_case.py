from bot.engine import case


class Answer:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


class Conn:
    def __init__(self, standing):
        self.standing = standing
        self.woke = []
        self.audited = []

    def execute(self, sql, params=None):
        if sql is case.STANDING:
            return Answer([self.standing] if self.standing else [])
        if sql is case.WAKE:
            self.woke.append(params)
            return Answer([])
        if "fd.audit" in sql:
            self.audited.append(params)
            return Answer([])
        raise AssertionError(f"unexpected query: {sql}")


def test_a_resolved_case_wakes_when_they_write_back():
    conn = Conn(("2026-08-20 10:00", "no_action", None))

    assert case.wake(conn, 3949, "UNEMO") == "no_action"
    assert conn.woke == [(3949,)]


def test_an_open_case_is_left_alone():
    conn = Conn((None, None, None))

    assert case.wake(conn, 3949, "UNEMO") is None
    assert conn.woke == []
    assert conn.audited == []


def test_a_case_merged_into_another_is_never_woken():
    conn = Conn(("2026-08-20 10:00", "duplicate", 3864))

    assert case.wake(conn, 3949, "UNEMO") is None
    assert conn.woke == [], "waking it would break the family it was merged into"


def test_a_case_that_is_gone_is_not_an_error():
    assert case.wake(Conn(None), 9999, "UNEMO") is None


def test_the_trail_says_why_it_came_back():
    conn = Conn(("2026-08-20 10:00", "action_taken", None))
    case.wake(conn, 3949, "UNEMO")

    said = conn.audited[0]
    assert said[2] == "case"
    assert said[4] == "reopened"
    assert said[0] == "UNEMO"


def test_waking_does_not_take_anybody_off_the_case():
    assert "case_assignees" not in case.WAKE, (
        "a reply is a continuation, so whoever held it keeps it"
    )
