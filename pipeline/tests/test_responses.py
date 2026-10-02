import pytest

from bot.nemo import responses
from bot.nemo.surface import autoresponse, unsub_shield

WHO = "U1"
ROOM = "CLOGS"
TS = "1700000000.000100"
THREAD = "1700000000.000000"

BODY = "here is why we do not name the reason"


class Conn:
    def __init__(self, rows=None, allows=True):
        self.rows = rows or []
        self.allows = allows
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchall(self):
        return self.rows

    def fetchone(self):
        return ("now",) if self.allows else None

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class Slack:
    def __init__(self, bot=False, gone=False):
        self.bot = bot
        self.gone = gone
        self.posted = []
        self.ephemeral = []

    def users_info(self, **kwargs):
        return {"user": {"is_bot": self.bot, "deleted": self.gone}}

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ts": "9.9"}

    def chat_postEphemeral(self, **kwargs):
        self.ephemeral.append(kwargs)
        return {"ok": True}


class Ctx:
    def __init__(self, event, client=None):
        self.payload = event
        self.client = client or Slack()


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False


@pytest.fixture(autouse=True)
def clean():
    responses._said.clear()
    responses._loaded = False
    yield
    responses._said.clear()
    responses._loaded = False


def load(**over):
    held = {
        responses.AUTORESPONSE_ON: "on",
        responses.AUTORESPONSE_EMOJI: "fd-reason,blunder",
        responses.AUTORESPONSE_CHANNEL: ROOM,
        responses.AUTORESPONSE_BODY: BODY,
        responses.AUTORESPONSE_COOLDOWN: "7",
        responses.UNSUB_SHIELD_ON: "on",
        responses.UNSUB_SHIELD_LINK: "https://unsub.hack.club",
    }
    held.update(over)
    responses.refresh(Conn(rows=list(held.items())))


def reacted(emoji="fd-reason", **over):
    return {"user": WHO, "reaction": emoji,
            "item": {"type": "message", "channel": ROOM, "ts": TS}, **over}


def posted(text="UNSUBSCRIBE", **over):
    return {"user": WHO, "channel": ROOM, "ts": TS, "thread_ts": THREAD,
            "text": text, **over}


def test_nothing_is_answered_before_the_settings_load():
    assert responses.answering(ROOM, "fd-reason") is False
    assert responses.shielding() is False


def test_the_reaction_is_answered(monkeypatch):
    load()
    conn = Conn()
    client = Slack()
    monkeypatch.setattr(autoresponse, "session", lambda: _held(conn))

    assert autoresponse.reacted(Ctx(reacted(), client)) == WHO
    assert client.posted[0]["channel"] == WHO
    assert client.posted[0]["text"] == BODY


def test_a_skin_tone_still_matches(monkeypatch):
    load()
    client = Slack()
    monkeypatch.setattr(autoresponse, "session", lambda: _held(Conn()))
    autoresponse.reacted(Ctx(reacted("fd-reason::skin-tone-3"), client))

    assert client.posted


def test_another_emoji_is_left_alone(monkeypatch):
    load()
    client = Slack()
    monkeypatch.setattr(autoresponse, "session", lambda: _held(Conn()))

    assert autoresponse.reacted(Ctx(reacted("tada"), client)) is None
    assert client.posted == []


def test_another_channel_is_left_alone(monkeypatch):
    load()
    client = Slack()
    monkeypatch.setattr(autoresponse, "session", lambda: _held(Conn()))
    event = reacted()
    event["item"]["channel"] = "CELSE"

    assert autoresponse.reacted(Ctx(event, client)) is None
    assert client.posted == []


def test_turned_off_answers_nobody(monkeypatch):
    load(**{responses.AUTORESPONSE_ON: "off"})
    client = Slack()
    monkeypatch.setattr(autoresponse, "session", lambda: _held(Conn()))

    assert autoresponse.reacted(Ctx(reacted(), client)) is None


def test_an_empty_reply_answers_nobody(monkeypatch):
    load(**{responses.AUTORESPONSE_BODY: ""})
    client = Slack()
    monkeypatch.setattr(autoresponse, "session", lambda: _held(Conn()))

    assert autoresponse.reacted(Ctx(reacted(), client)) is None


def test_the_cooldown_stops_a_second_answer(monkeypatch):
    load()
    client = Slack()
    monkeypatch.setattr(autoresponse, "session", lambda: _held(Conn(allows=False)))

    assert autoresponse.reacted(Ctx(reacted(), client)) is None
    assert client.posted == []


def test_a_bot_is_not_answered(monkeypatch):
    load()
    client = Slack(bot=True)
    monkeypatch.setattr(autoresponse, "session", lambda: _held(Conn()))

    assert autoresponse.reacted(Ctx(reacted(), client)) is None
    assert client.posted == []


def test_the_cooldown_is_checked_before_slack_is_asked(monkeypatch):
    load()
    conn = Conn(allows=False)
    monkeypatch.setattr(autoresponse, "session", lambda: _held(conn))
    autoresponse.reacted(Ctx(reacted()))

    assert conn.did("INSERT INTO fd.autoresponse_cooldown")


def test_the_cooldown_falls_back_when_it_is_odd():
    load(**{responses.AUTORESPONSE_COOLDOWN: "0"})
    assert responses.cooldown_days() == 7
    load(**{responses.AUTORESPONSE_COOLDOWN: "sideways"})
    assert responses.cooldown_days() == 7
    load(**{responses.AUTORESPONSE_COOLDOWN: "3"})
    assert responses.cooldown_days() == 3


def test_the_unsubscribe_is_taken_down(monkeypatch):
    load()
    client = Slack()
    taken = []
    monkeypatch.setattr(unsub_shield.guardwork, "remove",
                        lambda _c, room, ts: taken.append((room, ts)))

    assert unsub_shield.seen(Ctx(posted(), client)) is True
    assert taken == [(ROOM, TS)]
    assert "unsub.hack.club" in client.ephemeral[0]["text"]


def test_the_link_is_left_out_when_it_is_not_set(monkeypatch):
    load(**{responses.UNSUB_SHIELD_LINK: ""})
    client = Slack()
    monkeypatch.setattr(unsub_shield.guardwork, "remove", lambda *a: True)
    unsub_shield.seen(Ctx(posted(), client))

    assert "See how" not in client.ephemeral[0]["text"]


def test_lower_case_and_spaces_still_match(monkeypatch):
    load()
    taken = []
    monkeypatch.setattr(unsub_shield.guardwork, "remove",
                        lambda _c, room, ts: taken.append((room, ts)))
    unsub_shield.seen(Ctx(posted("  unsubscribe  ")))

    assert taken == [(ROOM, TS)]


def test_a_message_that_only_mentions_it_is_left_alone(monkeypatch):
    load()
    taken = []
    monkeypatch.setattr(unsub_shield.guardwork, "remove",
                        lambda _c, room, ts: taken.append((room, ts)))

    assert unsub_shield.seen(Ctx(posted("how do I UNSUBSCRIBE from this"))) is None
    assert taken == []


def test_one_outside_a_thread_is_left_alone(monkeypatch):
    load()
    taken = []
    monkeypatch.setattr(unsub_shield.guardwork, "remove",
                        lambda _c, room, ts: taken.append((room, ts)))

    assert unsub_shield.seen(Ctx(posted(thread_ts=None))) is None
    assert taken == []


def test_the_shield_turned_off_takes_nothing_down(monkeypatch):
    load(**{responses.UNSUB_SHIELD_ON: "off"})
    taken = []
    monkeypatch.setattr(unsub_shield.guardwork, "remove",
                        lambda _c, room, ts: taken.append((room, ts)))

    assert unsub_shield.seen(Ctx(posted())) is None
    assert taken == []
