import time

from lib import heartbeat


def test_beating_pulses_on_its_own_thread_and_evaluates_a_callable_note(monkeypatch):
    beats = []
    monkeypatch.setattr(heartbeat, "alive", lambda worker, note: beats.append((worker, note)))
    state = {"n": 0}

    with heartbeat.beating("test_worker", lambda: f"draining {state['n']}", every=0.01):
        time.sleep(0.05)
        state["n"] = 3
        time.sleep(0.05)

    assert len(beats) >= 3
    assert beats[0] == ("test_worker", "draining 0")
    assert ("test_worker", "draining 3") in beats


def test_beating_stops_when_the_block_exits(monkeypatch):
    beats = []
    monkeypatch.setattr(heartbeat, "alive", lambda worker, note: beats.append(note))
    with heartbeat.beating("w", "hello", every=0.01):
        time.sleep(0.03)
    settled = len(beats)
    time.sleep(0.05)
    assert len(beats) == settled


def test_a_plain_string_note_is_passed_through(monkeypatch):
    beats = []
    monkeypatch.setattr(heartbeat, "alive", lambda worker, note: beats.append(note))
    with heartbeat.beating("w", "idle", every=0.01):
        time.sleep(0.02)
    assert beats and all(n == "idle" for n in beats)
