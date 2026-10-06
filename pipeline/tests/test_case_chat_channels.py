import pytest

from bot.nemo import channel, chat


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


@pytest.fixture(autouse=True)
def forget(monkeypatch):
    monkeypatch.setattr(channel, "_internal_log", {})
    monkeypatch.setattr(channel, "_react", {})


def settings(monkeypatch, internal_log="C_FIRE", react=("C_REACT",)):
    monkeypatch.setattr(channel.channels, "setting", lambda conn, key: internal_log)
    monkeypatch.setattr(channel.channels, "react_channels", lambda conn: set(react))


def test_a_card_can_land_in_the_firehouse_or_a_react_channel(monkeypatch):
    settings(monkeypatch)
    assert channel.case_channels(Conn()) == {"C_FIRE", "C_REACT"}


def test_the_firehouse_alone_is_enough(monkeypatch):
    settings(monkeypatch, react=())
    assert channel.case_channels(Conn()) == {"C_FIRE"}


def test_the_channels_are_remembered_so_every_message_does_not_ask(monkeypatch):
    settings(monkeypatch)
    channel.case_channels(Conn())
    monkeypatch.setattr(channel.channels, "react_channels", lambda conn: 1 / 0)
    assert channel.case_channels() == {"C_FIRE", "C_REACT"}


def test_a_thread_on_no_case_names_none():
    assert chat.case_of_thread(Conn(), "100.000") is None


def test_the_thread_is_asked_for_by_name_not_by_position():
    conn = Conn({"SELECT case_id FROM (": (6,)})
    assert chat.case_of_thread(conn, "100.000") == 6
    assert conn.did("SELECT case_id FROM (")[0] == {"ts": "100.000"}


def test_thread_for_a_case_with_a_report_uses_its_forwarded_ts():
    conn = Conn({"SELECT coalesce(": ("200.000",)})
    assert channel.thread_for(conn, 412) == "200.000"


def test_thread_for_a_case_with_no_thread_at_all_is_none():
    conn = Conn()
    assert channel.thread_for(conn, 412) is None


class Slack:
    def __init__(self, fails=False):
        self.fails = fails
        self.posted = []

    def chat_postMessage(self, **kwargs):
        if self.fails:
            raise RuntimeError("slack said no")
        self.posted.append(kwargs)
        return {"ts": "9.9"}


def test_an_action_echo_quotes_a_report_thread(monkeypatch):
    monkeypatch.setattr(channel.profile, "profile",
        lambda client, user_id: {"name": user_id, "icon": None})
    conn = Conn({
        "SELECT coalesce(": ("100.000",),
        "SELECT card_channel_id": ("CROOM",),
    })
    client = Slack()

    ts = channel.post_action_echo(client, conn, 412,
        {"type_key": "warning", "target_user_id": "USUB", "reason": "kept at it"}, "UMOD")

    assert ts == "9.9"
    posted = client.posted[0]
    assert posted["channel"] == "CROOM"
    assert posted["thread_ts"] == "100.000"
    assert posted["blocks"][0]["text"]["text"] == "Warning"
    recorded = conn.did("INSERT INTO fd.case_chat")[0]
    assert recorded[0] == 412
    assert recorded[1] == "UMOD"
    assert recorded[2].obj == posted["blocks"]
    assert recorded[3:] == ("CROOM", "9.9", "9.9")


def test_an_action_echo_with_nowhere_to_go_posts_nothing(monkeypatch):
    conn = Conn()
    client = Slack()

    assert channel.post_action_echo(client, conn, 412,
        {"type_key": "warning", "target_user_id": "USUB", "reason": "kept at it"}, "UMOD") is None
    assert client.posted == []


def test_an_action_echo_slack_refuses_is_not_recorded(monkeypatch):
    monkeypatch.setattr(channel.profile, "profile",
        lambda client, user_id: {"name": user_id, "icon": None})
    conn = Conn({"SELECT coalesce(": ("100.000",), "SELECT card_channel_id": ("CROOM",)})
    client = Slack(fails=True)

    assert channel.post_action_echo(client, conn, 412,
        {"type_key": "warning", "target_user_id": "USUB", "reason": "kept at it"}, "UMOD") is None
    assert conn.did("INSERT INTO fd.case_chat") == []


def test_a_card_sitting_in_a_thread_can_name_its_case():
    assert "card_thread_ts = %(ts)s" in chat.CASE_OF_THREAD


def test_a_report_card_outranks_a_case_card():
    assert chat.CASE_OF_THREAD.index("fd.case_reports") < chat.CASE_OF_THREAD.index(
        "card_thread_ts = %(ts)s"
    )
