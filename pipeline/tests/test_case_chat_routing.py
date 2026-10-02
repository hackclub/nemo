import contextlib

import pytest

from bot.nemo import handlers
from bot.nemo.surface import ENTRIES, reaction_watch


class App:
    def action(self, key):
        return lambda fn: fn

    def view(self, key):
        return lambda fn: fn


class Ctx:
    def __init__(self, payload):
        self.payload = payload
        self.client = None


class Conn:
    def __init__(self):
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        return None


def watcher():
    return next(one for one in ENTRIES if one.tag == "handlers.on_message")


SAID = {"channel": "C_FIRE", "ts": "2.0", "thread_ts": "1.0", "user": "UFD"}


@pytest.fixture
def wired(monkeypatch):
    told = {"replied": [], "kept": []}

    handlers.register(App(), lambda *args, **kw: told["replied"].append((args, kw)))

    @contextlib.contextmanager
    def one_session():
        yield Conn()

    monkeypatch.setattr(handlers, "session", one_session)
    monkeypatch.setattr(handlers, "case_channels", lambda conn=None: {"C_FIRE"})
    monkeypatch.setattr(handlers.chat, "case_of_thread", lambda conn, ts: 6)
    monkeypatch.setattr(handlers.access, "may", lambda conn, who, needs, case=None: (True, None))
    monkeypatch.setattr(
        handlers.chat, "keep",
        lambda conn, case_id, event: (told["kept"].append((case_id, event)), (1, True))[1],
    )
    return told


def reaching(monkeypatch, answer):
    monkeypatch.setattr(handlers.chat, "reaches_a_member", lambda conn, ts: answer)


def test_a_question_on_a_report_thread_goes_to_the_member(wired, monkeypatch):
    reaching(monkeypatch, True)
    watcher().fn(Ctx(dict(SAID, text="?are you ok")))

    assert wired["replied"][0][0][1] == "are you ok"
    assert wired["kept"] == []


def test_a_question_with_no_member_to_reach_is_kept_as_chat(wired, monkeypatch):
    reaching(monkeypatch, False)
    watcher().fn(Ctx(dict(SAID, text="?are you ok")))

    assert wired["replied"] == []
    assert wired["kept"][0][0] == 6


def test_plain_chat_never_asks_whether_a_member_can_be_reached(wired, monkeypatch):
    monkeypatch.setattr(handlers.chat, "reaches_a_member", lambda conn, ts: 1 / 0)
    watcher().fn(Ctx(dict(SAID, text="who is handling this")))

    assert wired["kept"][0][0] == 6


ROOT = {"ts": "1.0", "user": "UMEM", "text": "that's my alt"}


def test_the_hourglassed_message_becomes_the_first_chat(monkeypatch):
    kept = []
    monkeypatch.setattr(
        reaction_watch.chat, "keep",
        lambda conn, case_id, event: (kept.append((case_id, event)), (7, True))[1],
    )
    assert reaction_watch.keep_the_root(None, 6, "C_FIRE", ROOT) == 7
    assert kept[0][1]["channel"] == "C_FIRE"
    assert kept[0][1]["text"] == "that's my alt"


@pytest.mark.parametrize("said", [
    {},
    {"ts": "1.0", "user": "UMEM"},
    {"ts": "1.0", "text": "a bot said this"},
    {"user": "UMEM", "text": "no timestamp"},
])
def test_a_root_the_chat_table_would_refuse_is_left_alone(said, monkeypatch):
    monkeypatch.setattr(
        reaction_watch.chat, "keep",
        lambda conn, case_id, event: 1 / 0,
    )
    assert reaction_watch.keep_the_root(None, 6, "C_FIRE", said) is None


def test_a_root_with_only_blocks_is_still_worth_keeping():
    assert reaction_watch.worth_keeping({"ts": "1.0", "user": "U1", "blocks": [{}]})
