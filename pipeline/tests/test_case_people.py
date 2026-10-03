from bot.nemo import case_actions
from bot.nemo.views import people

DROPPED = "detail"


class Conn:
    def __init__(self, rows=(), one=None):
        self.rows = rows
        self.one = one
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchall(self):
        return self.rows

    def fetchone(self):
        return self.one

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


def test_the_people_on_a_case_are_a_user_and_a_role():
    conn = Conn(rows=[("U1", "subject"), ("U2", "reporter")])

    assert case_actions.participants(conn, 6) == [
        {"user_id": "U1", "role": "subject"},
        {"user_id": "U2", "role": "reporter"},
    ]


def test_taking_somebody_off_writes_down_who_and_what_they_were():
    conn = Conn(one=("U1",))

    assert case_actions.remove_participant(conn, 6, "U1", "subject", "UFD") is True
    before = conn.did("INSERT INTO fd.audit")[0][5].obj
    assert before == {"user_id": "U1", "role": "subject"}


def test_taking_off_somebody_who_is_not_there_changes_nothing():
    conn = Conn(one=None)

    assert case_actions.remove_participant(conn, 6, "U1", "subject", "UFD") is False
    assert conn.did("INSERT INTO fd.audit") == []


def test_no_query_asks_for_the_column_0112_dropped():
    asked = [case_actions.PARTICIPANTS, case_actions.ADD_PARTICIPANT, case_actions.REMOVE_PARTICIPANT]
    assert [one for one in asked if DROPPED in one] == []


def test_the_people_modal_sends_only_what_the_table_holds():
    submitted_values = people.submitted_values({"values": {people.WHO: {people.WHO: {"selected_users": ["U1"]}}}})
    assert set(submitted_values) == {"user_ids", "role"}
