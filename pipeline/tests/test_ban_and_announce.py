import contextlib

import pytest

from bot.nemo import announce, channel
from bot.nemo.surface import reaction_watch
from bot.nemo.views import edit, linked

BOT = "UNEMO"
CHANNEL_ID = "C_FIRE"
CARD_TS = "100.000"


class Conn:
    def __init__(self, answers=None):
        self.answers = answers or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        for mark, row in self.answers.items():
            if mark in self.executed[-1][0]:
                return row
        return None

    def fetchall(self):
        for mark, rows in self.answers.items():
            if mark in self.executed[-1][0]:
                return rows
        return []

    def args_for(self, mark):
        return [args for sql, args in self.executed if mark in sql]


class Ctx:
    def __init__(self, payload):
        self.payload = payload
        self.client = None


def test_ban_prompt_returns_one_log_action_button_with_case_and_target():
    blocks = edit.ban_prompt(39, "UBAD")
    button = blocks[0]["elements"][0]
    assert [b["type"] for b in blocks] == ["actions"]
    assert button["text"]["text"] == "Log action"
    assert edit.parse_ban_value(button["value"]) == (39, "UBAD")
    assert edit.parse_ban_value(edit.ban_prompt(39)[0]["elements"][0]["value"]) == (39, None)


@pytest.fixture
def ban_calls(monkeypatch):
    recorded = {"prompted": [], "opened": [], "posted": []}

    @contextlib.contextmanager
    def fake_session():
        yield Conn({"FROM fd.case_reports WHERE forwarded_ts": recorded.get("card")})

    monkeypatch.setattr(reaction_watch, "session", fake_session)
    monkeypatch.setattr(reaction_watch.whoami, "bot_user_id", lambda client, name: BOT)
    monkeypatch.setattr(reaction_watch.access, "may",
                        lambda conn, user_id, capability, case=None: (True, None))
    monkeypatch.setattr(reaction_watch.channels, "react_channels", lambda conn=None: {"C_REACT"})
    monkeypatch.setattr(reaction_watch, "post_ban_prompt",
                        lambda client, conn, case_id, target: recorded["prompted"].append((case_id, target)))
    monkeypatch.setattr(reaction_watch, "thread_root",
                        lambda client, channel_id, ts: ("5.5", {"ts": "5.5", "user": "UBAD"}))
    monkeypatch.setattr(reaction_watch.case_queue, "case_for_root", lambda conn, channel_id, ts: None)
    monkeypatch.setattr(reaction_watch.case_actions, "open_case",
                        lambda conn, subject, body, user_id: recorded["opened"].append(user_id) or 77)
    monkeypatch.setattr(reaction_watch, "store_root_message", lambda conn, case_id, channel_id, message: None)
    monkeypatch.setattr(reaction_watch.case_queue, "post",
                        lambda client, conn, case_id, channel_id, thread_ts: recorded["posted"].append(case_id))
    return recorded


def ban_reaction(channel_id, ts, user_id="UME"):
    return Ctx({"reaction": "ban", "user": user_id,
                "item": {"type": "message", "channel": channel_id, "ts": ts}})


def test_prompt_action_log_on_ban_card_message_prompts_for_card_case(ban_calls):
    ban_calls["card"] = (23,)
    assert reaction_watch.prompt_action_log_on_ban(ban_reaction(CHANNEL_ID, CARD_TS)) == 23
    assert ban_calls["prompted"] == [(23, None)]
    assert ban_calls["opened"] == []


def test_prompt_action_log_on_ban_channel_message_opens_case_for_author(ban_calls):
    assert reaction_watch.prompt_action_log_on_ban(ban_reaction("C_REACT", "5.5")) == 77
    assert ban_calls["opened"] == ["UME"]
    assert ban_calls["posted"] == [77]
    assert ban_calls["prompted"] == [(77, "UBAD")]


def test_prompt_action_log_on_ban_other_channel_or_bot_user_returns_none(ban_calls):
    assert reaction_watch.prompt_action_log_on_ban(ban_reaction("C_ELSEWHERE", "5.5")) is None
    ban_calls["card"] = (23,)
    assert reaction_watch.prompt_action_log_on_ban(ban_reaction(CHANNEL_ID, CARD_TS, user_id=BOT)) is None
    assert ban_calls["prompted"] == []


def row(row_id, verb, entity, entity_id, actor="UFE", before=None, after=None, request="r1"):
    return (row_id, actor, entity, entity_id, verb, before, after, request)


def test_announcement_lines_fire_engine_rows_return_thread_lines(monkeypatch):
    monkeypatch.setattr(announce.channel, "case_url", lambda case_id: None)
    conn = Conn({"FROM fd.notes": (39, "spoke to them")})
    rows = [
        row(1, "claimed", "assignee", 39, request="a"),
        row(2, "attached", "assignee", 39, after={"user_id": "UA"}, request="b"),
        row(3, "attached", "assignee", 39, after={"user_id": "UB"}, request="b"),
        row(4, "detached", "assignee", 39, before={"user_id": "UA"}, request="c"),
        row(5, "unclaimed", "assignee", 39, before={"user_id": "UFE"}, request="d"),
        row(6, "noted", "note", 812, request="e"),
        row(7, "reopened", "case", 39, request="f"),
        row(8, "resolved", "case", 25, after={"resolution": "duplicate", "duplicate_of": 39},
            request="g"),
        row(9, "resolved", "case", 31, after={"resolution": "duplicate", "duplicate_of": 39},
            request="g"),
        row(10, "resolved", "case", 40, after={"resolution": "no_action"}, request="h"),
    ]

    announcements = announce.announcement_lines(conn, rows)

    assert announcements == [
        (39, "<@UFE> claimed case 39"),
        (39, "<@UFE> assigned case 39 to <@UA> and <@UB>"),
        (39, "<@UFE> unassigned <@UA> from case 39"),
        (39, "<@UFE> unassigned themselves from case 39"),
        (39, "<@UFE> added a note: spoke to them"),
        (39, "<@UFE> reopened case 39"),
        (39, "<@UFE> merged cases 25 and 31 into case 39 (this case)"),
        (25, "<@UFE> merged case 25 (this case) into case 39"),
        (31, "<@UFE> merged case 31 (this case) into case 39"),
    ]


def test_announcement_lines_fire_engine_unmerge_tells_both_threads(monkeypatch):
    monkeypatch.setattr(announce.channel, "case_url", lambda case_id: None)
    monkeypatch.setattr(announce.channel, "thread_url", lambda conn, case_id: f"https://slack/{case_id}")
    rows = [row(1, "unmerged", "case", 25, before={"duplicate_of": 39}, after={"duplicate_of": None})]

    assert announce.announcement_lines(Conn({}), rows) == [
        (39, "<@UFE> unmerged case 25 (<https://slack/25|Slack>) from case 39 (this case)"),
        (25, "<@UFE> unmerged case 25 (this case) from case 39 (<https://slack/39|Slack>)"),
    ]


def test_announce_advances_bot_cursor_to_last_row(monkeypatch):
    posted = []
    monkeypatch.setattr(announce.channel, "post_line",
                        lambda client, conn, case_id, text: posted.append(case_id) or "1.1")
    conn = Conn({"FROM fd.bot_cursor": (6,),
                 "FROM fd.audit": [row(7, "reopened", "case", 39), row(9, "reopened", "case", 40)]})

    assert announce.announce(None, conn) == 2
    assert posted == [39, 40]
    assert conn.args_for("UPDATE fd.bot_cursor")[0] == (9, "fire_engine_audit")


def test_announce_entries_query_filters_fire_engine_source():
    assert "source_app = 'fire_engine'" in announce.ENTRIES


LINK = "https://hackclub.slack.com/archives/C0BSBP62C3U/p1791730046580269"


def test_linked_occurrences_bare_link_returns_channel_and_timestamps():
    text = f"Testing links\n{LINK}?thread_ts=1791725791.702509&cid=C0BSBP62C3U"
    occurrences = linked.occurrences(text)
    assert [(one["channel_id"], one["ts"], one["thread_ts"]) for one in occurrences] == [
        ("C0BSBP62C3U", "1791730046.580269", "1791725791.702509")]


class Reader:
    def __init__(self, messages):
        self.messages = messages
        self.calls = []
        self.posted = []

    def conversations_replies(self, **kwargs):
        self.calls.append(("replies", kwargs))
        return {"messages": self.messages}

    def conversations_history(self, **kwargs):
        self.calls.append(("history", kwargs))
        return {"messages": self.messages}

    def conversations_join(self, **kwargs):
        self.calls.append(("join", kwargs))
        return {"ok": True}

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ts": "9.9"}


def inside():
    return Conn({"FROM fd.channel_membership WHERE channel_id": (True,)})


def test_read_linked_reply_in_thread_returns_source_message():
    reader = Reader([{"ts": "1791725791.702509", "text": "root"},
                     {"ts": "1791730046.580269", "text": "the reply", "user": "UA"}])

    linked_message = channel.read_linked(reader, inside(), "C0BSBP62C3U", "1791730046.580269",
                                         "1791725791.702509")

    assert reader.calls[0][0] == "replies"
    assert linked_message["source_body"] == "the reply" and linked_message["is_reachable"]
    assert linked_message["source_author_user_id"] == "UA"


def test_read_linked_missing_message_returns_none():
    assert channel.read_linked(Reader([]), inside(), "C1", "1.0") is None


def test_read_linked_joins_public_channel_before_reading():
    reader = Reader([{"ts": "1.0", "text": "hi", "user": "UA"}])
    conn = Conn()

    assert channel.read_linked(reader, conn, "C1", "1.0")["source_body"] == "hi"
    assert [name for name, _ in reader.calls] == ["join", "history"]
    assert conn.args_for("INSERT INTO fd.channel_membership") == [("C1", True)]


def test_read_linked_does_not_join_private_channel():
    reader = Reader([])

    assert channel.read_linked(reader, Conn(), "G1", "1.0") is None
    assert [name for name, _ in reader.calls] == ["history"]


def test_unfurl_opening_posts_link_once():
    text = f"Testing links\n{LINK}"
    reader = Reader([{"ts": "1791730046.580269", "text": "the reply", "user": "UA"}])
    conn = Conn({"unfurl_ts IS NULL\nORDER BY": (480, text)})

    assert channel.unfurl_opening(reader, conn, 39, CHANNEL_ID, CARD_TS) == "9.9"
    assert reader.posted[0]["thread_ts"] == CARD_TS
    assert conn.args_for("SET unfurl_ts")[0] == ("9.9", 480)

    assert channel.unfurl_opening(reader, Conn(), 39, CHANNEL_ID, CARD_TS) is None
