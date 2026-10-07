from contextlib import contextmanager
from types import SimpleNamespace

from bot.nemo.surface import channel_watch


def capture(monkeypatch):
    recorded = []

    @contextmanager
    def session():
        yield "conn"

    monkeypatch.setattr(channel_watch, "session", session)
    monkeypatch.setattr(channel_watch.channel_dim, "record",
                        lambda conn, channel_id, **seen: recorded.append((channel_id, seen)))
    return recorded


def test_a_renamed_channel_takes_its_new_name(monkeypatch):
    recorded = capture(monkeypatch)
    ctx = SimpleNamespace(payload={"type": "channel_rename", "channel": {"id": "C1", "name": "lounge"}})

    assert channel_watch.renamed(ctx) == "C1"
    assert recorded == [("C1", {"name": "lounge"})]


def test_a_rename_without_a_name_changes_nothing(monkeypatch):
    recorded = capture(monkeypatch)

    assert channel_watch.renamed(SimpleNamespace(payload={"channel": {"id": "C1"}})) is None
    assert channel_watch.renamed(SimpleNamespace(payload={"channel": "C1"})) is None
    assert recorded == []
