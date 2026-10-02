import json

from bot.nemo import guards, guardwork
from bot.nemo.cards import guard as card


def said_block(text):
    return {
        "type": "rich_text",
        "elements": [
            {"type": "rich_text_section", "elements": [{"type": "text", "text": text}]}
        ],
    }


def state(reason="enough", ticked=False, note=None):
    values = {card.REASON: {card.REASON: {"value": reason}}}
    if ticked:
        values[card.NOTE] = {card.NOTE: {"selected_options": [card.note_option()]}}
    if note is not None:
        values[card.SAID] = {card.SAID: {"rich_text_value": note}}
    return {"values": values}


def blocks_of(view):
    return [one.get("block_id") for one in view["blocks"]]


def test_the_modal_hides_the_note_field_until_it_is_asked_for():
    view = card.destroy_view("C1", "100.000")

    assert card.NOTE in blocks_of(view)
    assert card.SAID not in blocks_of(view)


def test_ticking_the_box_brings_the_note_field_out():
    said = card.picked(state(ticked=True))
    view = card.destroy_view("C1", "100.000", said=said)

    assert card.SAID in blocks_of(view)


def test_the_reason_survives_the_reshape():
    said = card.picked(state(reason="a raid", ticked=True))
    view = card.destroy_view("C1", "100.000", said=said)
    reason = next(one for one in view["blocks"] if one.get("block_id") == card.REASON)

    assert reason["element"]["initial_value"] == "a raid"


def test_the_note_survives_the_reshape():
    note = said_block("we removed this")
    said = card.picked(state(ticked=True, note=note))
    view = card.destroy_view("C1", "100.000", said=said)
    field = next(one for one in view["blocks"] if one.get("block_id") == card.SAID)

    assert field["element"]["initial_value"] == note


def test_the_toggle_asks_slack_to_tell_us_it_moved():
    view = card.destroy_view("C1", "100.000")
    toggle = next(one for one in view["blocks"] if one.get("block_id") == card.NOTE)

    assert toggle["dispatch_action"] is True
    assert toggle["optional"] is True


def test_a_ticked_but_empty_note_is_refused():
    said = card.picked(state(ticked=True))

    assert card.objection(said) == {card.SAID: "Write the note or untick it."}


def test_an_unticked_note_is_not_asked_for():
    assert card.objection(card.picked(state())) is None


def test_a_written_note_passes():
    said = card.picked(state(ticked=True, note=said_block("we removed this")))

    assert card.objection(said) is None


def test_the_note_is_flattened_for_the_record():
    said = card.picked(state(ticked=True, note=said_block("we removed this")))

    assert card.note_words(said) == "we removed this"


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


def test_keeping_a_note_writes_the_rich_text_and_the_words():
    conn = Conn()
    note = said_block("we removed this")
    guards.keep_note(conn, 9, note, "we removed this")

    said, text, guard_id = conn.did("SET note_said")[0]
    assert json.loads(said) == note
    assert text == "we removed this"
    assert guard_id == 9


class Client:
    def __init__(self, answer=None, blows_up=False):
        self.answer = answer or {"ts": "100.500"}
        self.blows_up = blows_up
        self.posted = []

    def chat_postMessage(self, **asked):
        if self.blows_up:
            raise RuntimeError("channel_not_found")
        self.posted.append(asked)
        return self.answer


def hold(monkeypatch, kept, seen=None):
    conn = Conn()
    kept_seen = [] if seen is None else seen
    monkeypatch.setattr(guards, "note_for", lambda _conn, _gid: kept)
    monkeypatch.setattr(guards, "note_posted",
                        lambda _conn, gid, ts: kept_seen.append((gid, ts)))
    monkeypatch.setattr(guardwork, "session", lambda: _Session(conn))
    return conn


class _Session:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *_):
        return False


def test_no_note_means_nothing_is_posted(monkeypatch):
    hold(monkeypatch, (None, None, None))
    client = Client()

    assert guardwork.leave_note(client, 9, "C1", "100.000", "UMOD") is None
    assert client.posted == []


def test_the_note_is_posted_into_the_thread_and_signed(monkeypatch):
    seen = []
    note = said_block("we removed this")
    hold(monkeypatch, (note, "we removed this", None), seen)
    client = Client()

    ts = guardwork.leave_note(client, 9, "C1", "100.000", "UMOD")

    assert ts == "100.500"
    assert seen == [(9, "100.500")]
    sent = client.posted[0]
    assert sent["thread_ts"] == "100.000"
    assert sent["text"] == "we removed this"
    assert sent["blocks"][0] == note
    assert "<@UMOD>" in sent["blocks"][1]["elements"][0]["text"]


def test_a_note_already_posted_is_not_posted_twice(monkeypatch):
    hold(monkeypatch, (said_block("x"), "x", "100.400"))
    client = Client()

    assert guardwork.leave_note(client, 9, "C1", "100.000", "UMOD") == "100.400"
    assert client.posted == []


def test_a_note_slack_refuses_does_not_stop_the_destroy(monkeypatch):
    hold(monkeypatch, (said_block("x"), "x", None))
    client = Client(blows_up=True)

    assert guardwork.leave_note(client, 9, "C1", "100.000", "UMOD") is None


def messages(*stamps):
    return [{"ts": ts} for ts in stamps]


def test_the_note_is_left_out_of_every_delete():
    said = messages("100.000", "100.100", "100.500", "100.200")

    assert guardwork.still_there(said, "100.000", "100.500") == ["100.100", "100.200"]


def test_the_root_goes_last_once_only_the_note_is_left():
    said = messages("100.000", "100.500")

    assert guardwork.still_there(said, "100.000", "100.500") == ["100.000"]


def test_without_a_note_nothing_changes():
    said = messages("100.000", "100.100")

    assert guardwork.still_there(said, "100.000") == ["100.100"]
    assert guardwork.still_there(messages("100.000"), "100.000") == ["100.000"]
