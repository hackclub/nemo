import contextlib

import pytest

from bot.nemo import channel, chat
from bot.nemo.surface import case_refs
from bot.nemo.views import case_refs as view

FIREHOUSE = "G0FIRE"
LOUNGE = "C0LOUNGE"


@pytest.mark.parametrize(("text", "expected"), [
    ("see also case #1234", [1234]),
    ("#1234 and #5633, also #1234 again", [1234, 5633]),
    ("(#1234), #1234.", [1234]),
    ("we're #1 and #12 on the list", []),
    ("abc#1234 #1234abc ##1234 &#1234; path/#1234", []),
    ("`#1234` and ```\n#5633\n```", []),
    ("<https://github.com/org/repo/pull/1#1234|PR #1234> <#C0LOUNGE|lounge>", []),
    ("#1234567", []),
    (None, []),
])
def test_numbers_finds_case_references(text, expected):
    assert case_refs.numbers(text) == expected


def test_numbers_stops_at_ten():
    text = " ".join(f"#{1000 + n}" for n in range(15))

    assert case_refs.numbers(text) == [1000 + n for n in range(10)]


def fe(case_id):
    return f"https://fe/cases/{case_id}"


def sl(case_id):
    return f"https://slack/{case_id}"


def test_line_links_fire_engine_and_the_slack_thread():
    assert view.line(1234, None, fe, sl) == "<https://fe/cases/1234|Case #1234> (<https://slack/1234|Slack>)"


def test_line_for_a_merged_case_names_its_main_case():
    assert view.line(1240, 1201, fe, sl) == (
        "<https://fe/cases/1240|Case #1240> (<https://slack/1240|Slack>) · merged into "
        "<https://fe/cases/1201|Case #1201> (<https://slack/1201|Slack>)"
    )


def test_line_without_links_is_plain():
    assert view.line(1234, None, lambda case_id: None, lambda case_id: None) == "Case #1234"


def test_message_is_a_small_context_block_with_plain_fallback():
    built = view.message([1234, 1240], ["first", "second"])

    assert built["text"] == "Case #1234, Case #1240"
    assert built["blocks"] == [{"type": "context", "elements": [{"type": "mrkdwn", "text": "first\nsecond"}]}]


class Conn:
    def __init__(self, cases=None, visibility="private"):
        self.cases = cases or {}
        self.visibility = visibility
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        self.last = (sql, args)
        return self

    def fetchone(self):
        sql, _args = self.last
        if sql == case_refs.VISIBILITY:
            return (self.visibility,) if self.visibility else None
        return None

    def fetchall(self):
        sql, args = self.last
        if sql == case_refs.CASES:
            return [(case_id, self.cases[case_id]) for case_id in args[0] if case_id in self.cases]
        return []


class Client:
    def __init__(self):
        self.posted = []

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ok": True}


class Ctx:
    def __init__(self, event):
        self.payload = event
        self.client = Client()


@pytest.fixture
def world(monkeypatch):
    state = {"conn": Conn({1234: None, 1240: 1201, 5633: None}), "own_case": None}

    @contextlib.contextmanager
    def session():
        yield state["conn"]

    monkeypatch.setattr(case_refs, "session", session)
    monkeypatch.setattr(channel, "case_channels", lambda conn=None: {FIREHOUSE})
    monkeypatch.setattr(channel, "log_channel", lambda conn=None: "C0LOGS")
    monkeypatch.setattr(channel, "case_url", fe)
    monkeypatch.setattr(channel, "thread_url", lambda conn, case_id: sl(case_id))
    monkeypatch.setattr(chat, "case_of_thread", lambda conn, thread_ts: state["own_case"])
    return state


def message(text, channel_id=FIREHOUSE, ts="1700000000.000100", **extra):
    return {"type": "message", "channel": channel_id, "user": "UMOD", "text": text, "ts": ts, **extra}


def test_reply_goes_in_the_thread_of_a_top_level_message(world):
    ctx = Ctx(message("see also case #1234"))

    assert case_refs.link_case_refs(ctx) == [1234]

    posted = ctx.client.posted[0]
    assert posted["channel"] == FIREHOUSE
    assert posted["thread_ts"] == "1700000000.000100"
    assert posted["unfurl_links"] is False and posted["unfurl_media"] is False
    assert posted["blocks"][0]["elements"][0]["text"] == \
        "<https://fe/cases/1234|Case #1234> (<https://slack/1234|Slack>)"


def test_reply_to_a_thread_reply_stays_in_that_thread(world):
    ctx = Ctx(message("#1240 is the same person", ts="1700000000.000300", thread_ts="1700000000.000100"))

    case_refs.link_case_refs(ctx)

    posted = ctx.client.posted[0]
    assert posted["thread_ts"] == "1700000000.000100"
    assert "merged into <https://fe/cases/1201|Case #1201>" in posted["blocks"][0]["elements"][0]["text"]


def test_one_reply_lists_every_case_and_skips_numbers_that_are_not_cases(world):
    ctx = Ctx(message("#5633 #9999 #1234"))

    assert case_refs.link_case_refs(ctx) == [5633, 1234]
    assert len(ctx.client.posted) == 1
    assert ctx.client.posted[0]["text"] == "Case #5633, Case #1234"


def test_the_internal_logs_channel_counts_as_an_fd_channel(world):
    ctx = Ctx(message("#1234", channel_id="C0LOGS"))

    assert case_refs.link_case_refs(ctx) == [1234]


@pytest.mark.parametrize("event", [
    message("#1234", bot_id="B0NEMO"),
    message("#1234", subtype="message_changed"),
    message("#1234", subtype="message_deleted"),
    message("#1234", channel_id=LOUNGE),
    message("no case here"),
    message("#9999"),
    message("!note same person as #1234", ts="1700000000.000300", thread_ts="1700000000.000100"),
])
def test_nothing_is_posted(world, event):
    ctx = Ctx(event)

    assert case_refs.link_case_refs(ctx) is None
    assert ctx.client.posted == []


def test_a_case_mentioned_in_its_own_thread_is_left_out(world):
    world["own_case"] = 1234
    ctx = Ctx(message("#1234 and #5633", ts="1700000000.000300", thread_ts="1700000000.000100"))

    assert case_refs.link_case_refs(ctx) == [5633]


def test_a_public_channel_is_left_alone(world):
    world["conn"].visibility = "public"
    ctx = Ctx(message("#1234"))

    assert case_refs.link_case_refs(ctx) is None
    assert ctx.client.posted == []
