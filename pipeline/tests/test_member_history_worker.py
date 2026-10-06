from datetime import datetime, timezone

from jobs import member_history_worker
from lib import settings


def at(hour):
    return datetime(2026, 10, 7, hour, 0, tzinfo=timezone.utc)


def wire(monkeypatch, landed):
    prepared = []
    monkeypatch.setattr(settings, "last_ok", lambda conn, key: landed.get(key))
    monkeypatch.setattr(member_history_worker, "prepare_member_history",
                        lambda conn: prepared.append(conn) or 3)
    return prepared


def test_the_first_wake_prepares_and_remembers_the_newest_input(monkeypatch):
    prepared = wire(monkeypatch, {"member_days": at(3), "member_range": at(4), "users_list": at(5)})

    assert member_history_worker.prepare_if_new("conn", None) == at(5)
    assert prepared == ["conn"]


def test_a_wake_with_no_new_input_skips_the_prep(monkeypatch):
    prepared = wire(monkeypatch, {"member_days": at(3), "member_range": at(4), "users_list": at(5)})

    assert member_history_worker.prepare_if_new("conn", at(5)) == at(5)
    assert prepared == []


def test_one_newer_input_is_enough_to_prepare_again(monkeypatch):
    prepared = wire(monkeypatch, {"member_days": at(6), "member_range": at(4), "users_list": at(5)})

    assert member_history_worker.prepare_if_new("conn", at(5)) == at(6)
    assert prepared == ["conn"]


def test_inputs_that_never_landed_still_prepare_once_per_wake(monkeypatch):
    prepared = wire(monkeypatch, {})

    assert member_history_worker.prepare_if_new("conn", None) is None
    assert prepared == ["conn"]
