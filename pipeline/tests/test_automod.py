import pytest

from bot.nemo import automod
from bot.nemo.surface import automod_watch

WHO = "U1"
ROOM = "C1"
TS = "1700000000.000100"


class Conn:
    def __init__(self, rows=(), keeps=True):
        self.rows = list(rows)
        self.keeps = keeps
        self.ran = []
        self.next_id = 0

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchall(self):
        return self.rows

    def fetchone(self):
        if not self.keeps:
            return None
        self.next_id += 1
        return (self.next_id,)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class Slack:
    def __init__(self, link="https://hackclub.slack.com/archives/C1/p1700000000000100"):
        self.link = link
        self.asked = []

    def chat_getPermalink(self, **kwargs):
        self.asked.append(kwargs)
        if self.link is None:
            raise RuntimeError("no permalink")
        return {"permalink": self.link}


class Ctx:
    def __init__(self, event, client=None):
        self.payload = event
        self.client = client or Slack()


def message(text, **over):
    return {"user": WHO, "channel": ROOM, "ts": TS, "text": text, **over}


def edited(text, **over):
    return {
        "subtype": "message_changed",
        "channel": ROOM,
        "ts": "1700000009.000000",
        "message": {"user": WHO, "ts": TS, "text": text, **over},
    }


@pytest.fixture(autouse=True)
def clean():
    automod._watching[:] = []
    automod._loaded = False
    yield
    automod._watching[:] = []
    automod._loaded = False


def load(*rows):
    conn = Conn(rows)
    automod.refresh(conn)
    return conn


def test_nothing_is_read_before_the_list_is_loaded():
    assert automod.watching() is None
    assert automod.caught("anything at all") == []


def test_a_whole_word_does_not_match_inside_another_word():
    load((1, "ass", "word", "flag", None))

    assert automod.caught("that was an ass move")
    assert automod.caught("she is classy") == []
    assert automod.caught("passing through") == []


def test_a_whole_word_matches_against_punctuation():
    load((1, "badword", "word", "flag", None))

    assert automod.caught("badword!")
    assert automod.caught("(badword)")
    assert automod.caught("...badword...")


def test_a_substring_matches_inside_a_word():
    load((1, "spam", "substring", "flag", None))

    assert automod.caught("antispamming")


def test_a_regex_matches_what_it_says():
    load((1, "ba+dword", "regex", "flag", None))

    assert automod.caught("baaadword")
    assert automod.caught("bdword") == []


def test_matching_ignores_case():
    load((1, "badword", "word", "flag", None))

    assert automod.caught("BadWord")


def test_a_regex_that_does_not_compile_is_left_out():
    load((1, "([a-z", "regex", "flag", None), (2, "fine", "word", "flag", None))

    assert len(automod.watching()) == 1
    assert automod.caught("fine")


def test_a_blank_word_is_left_out():
    load((1, "   ", "word", "flag", None))

    assert automod.watching() == []


def test_every_matching_word_is_caught():
    load((1, "one", "word", "flag", None), (2, "two", "word", "flag", None))

    assert len(automod.caught("one and two")) == 2


def test_refresh_replaces_what_was_held():
    load((1, "gone", "word", "flag", None))
    load((2, "fresh", "word", "flag", None))

    assert automod.caught("gone") == []
    assert automod.caught("fresh")


def test_a_match_is_recorded_with_the_message_kept():
    load((1, "badword", "word", "flag", "spam"))
    conn = Conn()
    watch = automod.caught("a badword here")[0]
    automod.record(conn, watch, message("a badword here"))

    kept = conn.did("INSERT INTO fd.automod_matches")[0]
    assert kept[1] == "badword"
    assert kept[3] == WHO
    assert kept[4] == ROOM
    assert kept[7] == "a badword here"


def test_the_watcher_records_what_it_catches(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))

    assert automod_watch.watched(Ctx(message("a badword here"))) == 1
    assert conn.did("INSERT INTO fd.automod_matches")


def test_the_watcher_leaves_a_clean_message_alone(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))

    assert automod_watch.watched(Ctx(message("nothing to see"))) is None
    assert not conn.did("INSERT INTO fd.automod_matches")


def test_the_watcher_ignores_a_bot(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))

    assert automod_watch.watched(Ctx(message("badword", bot_id="B1"))) is None
    assert not conn.did("INSERT INTO fd.automod_matches")


def test_an_edit_that_adds_a_word_is_caught(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))

    assert automod_watch.watched(Ctx(edited("now with a badword"))) == 1
    kept = conn.did("INSERT INTO fd.automod_matches")[0]
    assert kept[5] == TS
    assert kept[7] == "now with a badword"


def test_an_edit_records_against_the_message_not_the_edit():
    load((1, "badword", "word", "flag", None))
    held = automod_watch.message_in(edited("a badword"))

    assert held["ts"] == TS
    assert held["user"] == WHO
    assert held["channel"] == ROOM


def test_a_clean_edit_records_nothing(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))

    assert automod_watch.watched(Ctx(edited("all tidied up now"))) is None
    assert not conn.did("INSERT INTO fd.automod_matches")


def test_an_edit_by_a_bot_is_left_alone(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))

    assert automod_watch.watched(Ctx(edited("badword", bot_id="B1"))) is None


def test_an_unfurl_that_matches_nothing_new_costs_no_permalink(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn(keeps=False)
    client = Slack()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))
    automod_watch.watched(Ctx(edited("a badword here"), client))

    assert client.asked == []


def test_the_watcher_says_nothing_to_the_author(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    client = Slack()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))
    automod_watch.watched(Ctx(message("a badword here"), client))

    assert not hasattr(client, "posted")
    assert not conn.did("DELETE")


def test_a_message_already_recorded_is_not_counted_twice(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn(keeps=False)
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))

    assert automod_watch.watched(Ctx(message("a badword here"))) is None


def test_a_missing_permalink_does_not_stop_the_record(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))
    automod_watch.watched(Ctx(message("a badword here"), Slack(link=None)))

    assert conn.did("INSERT INTO fd.automod_matches")
    assert not conn.did("SET permalink")


def test_a_permalink_is_only_fetched_for_a_fresh_match(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn(keeps=False)
    client = Slack()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))
    automod_watch.watched(Ctx(message("a badword here"), client))

    assert client.asked == []


def test_a_fresh_match_is_linked(monkeypatch):
    load((1, "badword", "word", "flag", None))
    conn = Conn()
    client = Slack()
    monkeypatch.setattr(automod_watch, "session", lambda: _held(conn))
    automod_watch.watched(Ctx(message("a badword here"), client))

    assert client.asked == [{"channel": ROOM, "message_ts": TS}]
    assert conn.did("SET permalink")[0][0] == client.link


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False
