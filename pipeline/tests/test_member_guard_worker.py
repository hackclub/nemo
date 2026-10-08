import inspect

from bot.nemo import loop


class _held:
    def __enter__(self):
        return object()

    def __exit__(self, *failure):
        return False


def guard(guard_id, kind="shush"):
    return {"id": guard_id, "kind": kind, "subject_id": "U1", "channel_id": None,
            "reason": "spam", "expires_at": None}


def wired(monkeypatch, pending=(), lifting=(), failing=()):
    taken, released = [], []

    def take_up(client, one):
        if one["id"] in failing:
            raise RuntimeError("slack is down")
        taken.append(one["id"])

    monkeypatch.setattr(loop, "session", lambda: _held())
    monkeypatch.setattr(loop.memberguards, "refresh", lambda conn: 0)
    monkeypatch.setattr(loop.memberguards, "unenforced", lambda conn: list(pending))
    monkeypatch.setattr(loop.memberguards, "still_lifting", lambda conn: list(lifting))
    monkeypatch.setattr(loop, "take_up", take_up)
    monkeypatch.setattr(loop.sweep, "release_now",
                        lambda client, one: released.append(one["id"]))
    return taken, released


def test_a_flush_takes_up_what_is_pending_and_finishes_what_is_lifting(monkeypatch):
    taken, released = wired(monkeypatch, pending=[guard(1), guard(2)],
                            lifting=[guard(3, "deactivation")])

    loop.flush_pending(object())

    assert taken == [1, 2]
    assert released == [3]


def test_one_guard_failing_does_not_stop_the_rest(monkeypatch):
    taken, _released = wired(monkeypatch, pending=[guard(1), guard(2)], failing={1})

    loop.flush_pending(object())

    assert taken == [2]


def test_a_flush_never_asks_the_worker_to_go_straight_again(monkeypatch):
    wired(monkeypatch, pending=[guard(1)])

    assert not loop.flush_pending(object())


def test_the_sweep_leaves_member_guards_to_the_worker():
    swept = inspect.getsource(loop.once)

    assert "unenforced" not in swept
    assert "take_up" not in swept
    assert "sweep_lifting" not in swept


def test_a_member_guard_notification_wakes_the_worker_instead_of_a_thread():
    started = inspect.getsource(loop.start)

    assert 'loops.draining(f"{NAME}-member-guards"' in started
    assert "target=flush_pending" not in started
