import pytest

from bot.nemo import queued

FIREHOUSE = "C_FIRE"
THREAD = "100.000"


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

    def fetchall(self):
        return []

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class Slack:
    def __init__(self):
        self.posted = []

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ts": "9.9"}


@pytest.fixture(autouse=True)
def firehouse(monkeypatch):
    monkeypatch.setattr(queued, "firehouse_channel", lambda conn=None: FIREHOUSE)


def opened(card_ts=None, reported=False):
    return {
        "SELECT id, category_key": (41, None, None, None, card_ts, None),
        "FOR UPDATE": (card_ts,),
        "NOT EXISTS (SELECT 1 FROM fd.case_reports": None if reported or card_ts else (1,),
    }


def test_a_case_opened_without_a_report_gets_a_card_in_the_firehouse():
    conn, slack = Conn(opened()), Slack()

    ts = queued.card(slack, conn, 41)

    assert ts == "9.9"
    assert slack.posted[0]["channel"] == FIREHOUSE
    assert slack.posted[0]["thread_ts"] is None
    assert conn.did("UPDATE fd.cases SET card_channel_id")[0][:3] == (FIREHOUSE, None, "9.9")


def test_a_card_can_be_sent_somewhere_other_than_the_firehouse():
    conn, slack = Conn(opened()), Slack()

    queued.card(slack, conn, 41, "C_ELSE")

    assert slack.posted[0]["channel"] == "C_ELSE"


def test_a_case_that_came_in_as_a_report_is_left_to_its_report_card():
    conn, slack = Conn(opened(reported=True)), Slack()

    assert queued.card(slack, conn, 41) is None
    assert slack.posted == []


def test_a_case_that_already_has_a_card_does_not_get_a_second_one():
    conn, slack = Conn(opened(card_ts="8.8")), Slack()

    assert queued.card(slack, conn, 41) is None
    assert queued.post(slack, conn, 41, FIREHOUSE) == "8.8"
    assert slack.posted == []


def test_a_card_claimed_while_we_were_asking_is_left_alone():
    conn, slack = Conn(opened()), Slack()
    conn.rows["FOR UPDATE"] = ("7.7",)

    assert queued.post(slack, conn, 41, FIREHOUSE) == "7.7"
    assert slack.posted == []


def test_a_thread_card_still_goes_into_its_thread():
    conn, slack = Conn(opened()), Slack()

    queued.post(slack, conn, 41, "C1", THREAD)

    assert slack.posted[0]["thread_ts"] == THREAD
    assert conn.did("UPDATE fd.cases SET card_channel_id")[0][:3] == ("C1", THREAD, "9.9")
