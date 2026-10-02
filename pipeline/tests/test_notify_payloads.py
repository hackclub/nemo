import threading

from bot.core import loops


class Note:
    def __init__(self, channel, payload):
        self.channel = channel
        self.payload = payload


class FakeConn:
    def __init__(self, notes):
        self.notes = notes
        self.listening = []
        self.autocommit = False

    def execute(self, said):
        self.listening.append(said)

    def notifies(self, stop_after=None, timeout=None):
        return iter(self.notes)

    def close(self):
        pass


def what_was_heard(monkeypatch, notes):
    monkeypatch.setattr(loops, "connect", lambda: FakeConn(notes))
    got = []
    loops.listen(
        "nemo", ("fd_channel_guard",), lambda name, told: got.append((name, told)),
        threading.Event(),
    )
    return got


def test_a_channel_id_payload_reaches_the_listener(monkeypatch):
    got = what_was_heard(monkeypatch, [Note("fd_channel_guard", "C0BAHBV008Z")])
    assert got == [("fd_channel_guard", "C0BAHBV008Z")]


def test_a_numeric_payload_still_arrives_as_a_number(monkeypatch):
    got = what_was_heard(monkeypatch, [Note("fd_case_changed", "41")])
    assert got == [("fd_case_changed", 41)]


def test_an_empty_payload_is_dropped(monkeypatch):
    assert what_was_heard(monkeypatch, [Note("fd_channel_guard", "")]) == []
