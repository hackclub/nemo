import contextlib
import inspect
import threading
from types import SimpleNamespace

import pytest

from bot.nemo import channel, chat, loop


class Conn:
    def __init__(self, rows=None, lists=None):
        self.rows = rows or {}
        self.lists = lists or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        for mark, row in self.rows.items():
            if mark in self.executed[-1][0]:
                return row
        return None

    def fetchall(self):
        for mark, rows in self.lists.items():
            if mark in self.executed[-1][0]:
                return rows
        return []

    def args_for(self, mark):
        return [args for sql, args in self.executed if mark in sql]


@pytest.fixture(autouse=True)
def reset_channel_cache(monkeypatch):
    monkeypatch.setattr(channel, "_settings", {})
    monkeypatch.setattr(channel, "_react", {})
    monkeypatch.setattr(channel, "_cards", {}, raising=False)


def settings(monkeypatch, firehouse="C_FIRE", reports=None, logs=None, react=("C_REACT",)):
    values = {channel.channels.FIREHOUSE: firehouse, channel.channels.REPORTS: reports,
              channel.channels.LOGS: logs}
    monkeypatch.setattr(channel.channels, "setting", lambda conn, key: values.get(key))
    monkeypatch.setattr(channel.channels, "react_channels", lambda conn: set(react))


def test_case_channels_returns_firehouse_and_react_channels(monkeypatch):
    settings(monkeypatch)
    assert channel.case_channels(Conn()) == {"C_FIRE", "C_REACT"}


def test_case_channels_without_react_channels_returns_firehouse(monkeypatch):
    settings(monkeypatch, react=())
    assert channel.case_channels(Conn()) == {"C_FIRE"}


def test_case_channels_second_call_uses_cache(monkeypatch):
    settings(monkeypatch)
    channel.case_channels(Conn())
    monkeypatch.setattr(channel.channels, "react_channels", lambda conn: 1 / 0)
    assert channel.case_channels() == {"C_FIRE", "C_REACT"}


CARD_ROWS = {"FROM fd.case_reports WHERE card_channel_id IS NOT NULL": [("C_OLDFIRE",), ("G01DBHPLK25",)]}


def test_case_channels_after_firehouse_change_includes_card_channels(monkeypatch):
    settings(monkeypatch, firehouse="C_NEWFIRE")

    assert channel.case_channels(Conn(lists=CARD_ROWS)) == {"C_NEWFIRE", "C_REACT", "C_OLDFIRE", "G01DBHPLK25"}


def test_card_channels_query_reads_reports_and_cases():
    assert "FROM fd.case_reports WHERE card_channel_id IS NOT NULL" in channel.CARD_CHANNELS
    assert "FROM fd.cases WHERE card_channel_id IS NOT NULL" in channel.CARD_CHANNELS


def test_card_channels_after_refresh_returns_cached_channels(monkeypatch):
    settings(monkeypatch)
    channel.refresh_channels(Conn(lists=CARD_ROWS))

    assert channel.card_channels() == {"C_OLDFIRE", "G01DBHPLK25"}
    assert "C_OLDFIRE" in channel.case_channels()


def capture_refreshes(monkeypatch):
    refreshed_conns = []
    monkeypatch.setattr(loop.channel, "refresh_channels", lambda conn: refreshed_conns.append(conn))
    return refreshed_conns


def test_sweep_once_calls_refresh_channels():
    assert "channel.refresh_channels(conn)" in inspect.getsource(loop.sweep_once)


def test_start_app_setting_notify_refreshes_channels(monkeypatch):
    conn = Conn()
    refreshed_conns = capture_refreshes(monkeypatch)
    listener_handlers = {}

    @contextlib.contextmanager
    def fake_session():
        yield conn

    monkeypatch.setattr(loop, "session", fake_session)
    for module in (loop.guards, loop.channelguards, loop.memberguards, loop.automod,
                   loop.responses, loop.screening):
        monkeypatch.setattr(module, "refresh", lambda conn: 0)
    monkeypatch.setattr(loop.purge, "requeue_interrupted", lambda conn: [])
    monkeypatch.setattr(loop.loops, "run_on_wake", lambda *args, **kwargs: (lambda: None))
    monkeypatch.setattr(loop.loops, "start_listener",
                        lambda name, names, on_notify, stopping: listener_handlers.update(on_notify=on_notify))
    monkeypatch.setattr(loop.loops, "run_periodically", lambda *args, **kwargs: None)
    monkeypatch.setattr(loop.loops, "run_on_timer", lambda *args, **kwargs: (lambda: None))
    monkeypatch.setattr(loop, "start_configured_joins", lambda client: None)

    loop.start(SimpleNamespace(client=None), threading.Event())
    refreshed_conns.clear()
    listener_handlers["on_notify"](loop.APP_SETTING, "nemo.firehouse_channel")

    assert refreshed_conns == [conn]


def test_case_of_thread_without_case_returns_none():
    assert chat.case_of_thread(Conn(), "100.000") is None


def test_case_of_thread_passes_ts_as_named_parameter():
    conn = Conn({"SELECT case_id FROM (": (6,)})
    assert chat.case_of_thread(conn, "100.000") == 6
    assert conn.args_for("SELECT case_id FROM (")[0] == {"ts": "100.000"}


def test_thread_for_case_with_report_returns_forwarded_ts():
    conn = Conn({"SELECT coalesce(": ("200.000",)})
    assert channel.thread_for(conn, 412) == "200.000"


def test_thread_for_case_without_thread_returns_none():
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


def test_post_action_log_in_report_thread_posts_and_records_chat_row(monkeypatch):
    monkeypatch.setattr(channel.profile, "profile",
        lambda client, user_id: {"name": user_id, "icon": None})
    conn = Conn({
        "r.forwarded_ts FROM": ("100.000",),
        "card_channel_id FROM": ("CCARD",),
    })
    client = Slack()

    ts = channel.post_action_log(client, conn, 412,
        {"type_key": "warning", "target_user_id": "USUB", "reason": "kept at it"}, "UMOD")

    assert ts == "9.9"
    posted = client.posted[0]
    assert posted["channel"] == "CCARD"
    assert posted["thread_ts"] == "100.000"
    assert posted["blocks"][0]["text"]["text"] == "Warning"
    chat_row = conn.args_for("INSERT INTO fd.case_chat")[0]
    assert chat_row[0] == 412
    assert chat_row[1] == "UMOD"
    assert chat_row[2].obj == posted["blocks"]
    assert chat_row[3:] == ("CCARD", "9.9", "9.9")


def test_post_action_log_channel_ban_text_names_channel_and_expiry(monkeypatch):
    monkeypatch.setattr(channel.profile, "profile",
        lambda client, user_id: {"name": user_id, "icon": None})
    conn = Conn({
        "r.forwarded_ts FROM": ("100.000",),
        "card_channel_id FROM": ("CCARD",),
        "SELECT name FROM raw.channel_dim": ("general",),
    })
    client = Slack()

    channel.post_action_log(client, conn, 412, {
        "type_key": "channel_ban", "target_user_id": "USUB", "reason": "kept at it",
        "channel_id": "CGEN", "expires_on": "2026-03-10",
    }, "UMOD")

    posted = client.posted[0]
    assert posted["blocks"][0]["text"]["text"] == "Channel ban from #general"
    assert posted["blocks"][1]["elements"][0]["text"] == "Against <@USUB> until 10 Mar, logged by <@UMOD>"
    assert conn.args_for("SELECT name FROM raw.channel_dim")[0] == ("CGEN",)


def test_post_action_log_without_card_channel_does_not_post(monkeypatch):
    conn = Conn()
    client = Slack()

    assert channel.post_action_log(client, conn, 412,
        {"type_key": "warning", "target_user_id": "USUB", "reason": "kept at it"}, "UMOD") is None
    assert client.posted == []


def test_post_action_log_slack_error_returns_none_without_chat_row(monkeypatch):
    monkeypatch.setattr(channel.profile, "profile",
        lambda client, user_id: {"name": user_id, "icon": None})
    conn = Conn({"r.forwarded_ts FROM": ("100.000",), "card_channel_id FROM": ("CCARD",)})
    client = Slack(fails=True)

    assert channel.post_action_log(client, conn, 412,
        {"type_key": "warning", "target_user_id": "USUB", "reason": "kept at it"}, "UMOD") is None
    assert conn.args_for("INSERT INTO fd.case_chat") == []


def test_post_resolution_log_in_report_thread_posts_and_records_chat_row(monkeypatch):
    monkeypatch.setattr(channel.profile, "profile",
        lambda client, user_id: {"name": user_id, "icon": None})
    conn = Conn({
        "r.forwarded_ts FROM": ("100.000",),
        "card_channel_id FROM": ("CCARD",),
    })
    client = Slack()

    ts = channel.post_resolution_log(client, conn, 412, "no_action", None, "UMOD")

    assert ts == "9.9"
    posted = client.posted[0]
    assert posted["channel"] == "CCARD"
    assert posted["thread_ts"] == "100.000"
    assert posted["text"] == "No action needed"
    chat_row = conn.args_for("INSERT INTO fd.case_chat")[0]
    assert chat_row[0] == 412
    assert chat_row[1] == "UMOD"
    assert chat_row[2].obj == posted["blocks"]
    assert chat_row[3:] == ("CCARD", "9.9", "9.9")


def test_post_resolution_log_without_card_channel_does_not_post():
    conn = Conn()
    client = Slack()

    assert channel.post_resolution_log(client, conn, 412, "no_action", None, "UMOD") is None
    assert client.posted == []


class FetchallConn:
    def __init__(self, rows):
        self.rows = rows

    def execute(self, sql, args=None):
        return self

    def fetchall(self):
        return self.rows


def test_post_follow_ups_failing_message_does_not_block_remaining_messages(monkeypatch):
    follow_up_ids = []

    def fake_post_follow_up(client, conn, message_id, channel_id):
        follow_up_ids.append(message_id)
        if message_id == 46:
            raise RuntimeError("invalid_blocks")
        return "9.9"

    monkeypatch.setattr(channel, "post_follow_up", fake_post_follow_up)
    conn = FetchallConn([(46,), (47,), (48,)])

    assert channel.post_follow_ups(Slack(), conn, 19) == 2
    assert follow_up_ids == [46, 47, 48]


def test_post_files_failing_share_does_not_block_remaining_files(monkeypatch):
    shared_ids = []

    def fake_share(client, conn, message_id, channel_id, forwarded_ts, author_fields=None):
        shared_ids.append(message_id)
        if message_id == 46:
            raise RuntimeError("invalid_blocks")
        return "9.9"

    monkeypatch.setattr(channel.attachments, "share", fake_share)
    monkeypatch.setattr(channel, "reporter_author_fields", lambda client, anonymous, reporter: {})
    conn = FetchallConn([
        (46, "100.000", False, "U1", None),
        (47, "100.000", False, "U1", None),
    ])

    assert channel.post_files(Slack(), conn, 19, "CCARD") == 1
    assert shared_ids == [46, 47]


def report_case(**over):
    case = {"forwarded_ts": None, "report_id": 2, "message_id": 3,
            "is_anonymous": False, "reporter_user_id": "U1"}
    case.update(over)
    return case


def stub_report_views(monkeypatch):
    monkeypatch.setattr(channel.views.report, "build_blocks", lambda case: [])
    monkeypatch.setattr(channel.views.report, "fallback", lambda case: "fallback")
    monkeypatch.setattr(channel.views.report, "metadata", lambda case: {})
    monkeypatch.setattr(channel.card_facts, "enrich", lambda *args, **kwargs: None)
    monkeypatch.setattr(channel.views.case_card, "digest", lambda case: "digest")
    monkeypatch.setattr(channel.attachments, "share", lambda *args, **kwargs: None)


def test_post_report_updates_intake_message_with_card_ts(monkeypatch):
    stub_report_views(monkeypatch)
    monkeypatch.setattr(channel, "fetch_case", lambda conn, case_id: report_case())
    conn = Conn()

    ts = channel.post_report(Slack(), conn, 2, "CNEW")

    assert ts == "9.9"
    assert conn.args_for("UPDATE fd.intake_messages")[0] == ("9.9", None, 3)


def test_post_report_with_mirrored_ts_updates_intake_message_with_card_ts(monkeypatch):
    stub_report_views(monkeypatch)
    monkeypatch.setattr(
        channel, "fetch_case", lambda conn, case_id: report_case(mirrored_ts="OLD.TS")
    )
    conn = Conn()

    channel.post_report(Slack(), conn, 2, "CNEW")

    assert conn.args_for("UPDATE fd.intake_messages")[0] == ("9.9", None, 3)


def test_case_of_thread_query_matches_card_thread_ts():
    assert "card_thread_ts = %(ts)s" in chat.CASE_OF_THREAD


def test_case_of_thread_query_checks_case_reports_before_card_thread_ts():
    assert chat.CASE_OF_THREAD.index("fd.case_reports") < chat.CASE_OF_THREAD.index(
        "card_thread_ts = %(ts)s"
    )
