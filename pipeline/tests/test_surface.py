import contextlib

import pytest
import yaml

from bot.nemo import app as nemo_app  # noqa: F401  registers every surface
from bot.nemo import handlers, surface
from lib.paths import CAPABILITIES_FILE

CAPABILITIES = yaml.safe_load(CAPABILITIES_FILE.read_text())["capabilities"]


def test_surface_entries_declare_capability_or_open_to_all():
    undeclared = [one for one in surface.ENTRIES if not one.open_to_all and not one.needs]
    assert undeclared == [], f"these write without declaring a capability: {undeclared}"


def test_surface_entry_capabilities_exist_in_capabilities_file():
    named = {one.needs for one in surface.ENTRIES if one.needs}
    assert named <= set(CAPABILITIES), f"unknown capabilities: {named - set(CAPABILITIES)}"


def test_declared_undeclared_entry_raises_undeclared_capability_error():
    entry = surface.SurfaceEntry(surface.ACTION, "loose_button", None, lambda ctx: None)
    surface.ENTRIES.append(entry)
    try:
        with pytest.raises(surface.UndeclaredCapabilityError):
            surface.declared()
    finally:
        surface.ENTRIES.remove(entry)


def test_thread_guard_surfaces_are_registered():
    keys = {(one.kind, one.key) for one in surface.ENTRIES}
    assert ("shortcut", "destroy_thread") in keys
    assert ("shortcut", "lock_thread") in keys
    assert ("view", "thread_destroy") in keys
    assert ("view", "thread_lock") in keys


def test_team_join_event_has_only_record_team_join_handler():
    from bot.nemo.surface import join_watch

    join_handlers = [one.fn for one in surface.ENTRIES if (one.kind, one.key) == (surface.EVENT, "team_join")]
    assert join_handlers == [join_watch.record_team_join], "a second fd.member_joins writer makes every joiner look known"


def test_event_entries_are_open_to_all():
    event_entries = [one for one in surface.ENTRIES if one.kind == surface.EVENT]
    assert event_entries, "the guarded-thread watcher is not registered"
    assert all(one.open_to_all for one in event_entries)


def test_run_entries_calls_every_handler_for_key():
    calls = []
    entries = [
        surface.SurfaceEntry(surface.EVENT, "message", None, lambda ctx: calls.append("first"),
                      open_to_all=True),
        surface.SurfaceEntry(surface.EVENT, "message", None, lambda ctx: calls.append("second"),
                      open_to_all=True),
    ]
    surface.run_entries(entries)(ack=None, body={}, client=None, payload={})
    assert calls == ["first", "second"], "bolt stops at the first answer, so we must fan out"


def test_run_entries_failing_handler_does_not_stop_others():
    calls = []

    def raising_handler(ctx):
        raise RuntimeError("no")

    entries = [
        surface.SurfaceEntry(surface.EVENT, "message", None, raising_handler, open_to_all=True),
        surface.SurfaceEntry(surface.EVENT, "message", None, lambda ctx: calls.append("still ran"),
                      open_to_all=True),
    ]
    surface.run_entries(entries)(ack=None, body={}, client=None, payload={})
    assert calls == ["still ran"], "a handler that throws must not take the others down"


def test_guarded_event_without_ack_runs_handler():
    calls = []
    entry = surface.SurfaceEntry(surface.EVENT, "message", None, lambda ctx: calls.append("ok"),
                          open_to_all=True)
    surface.guarded(entry)(ack=None, body={}, client=None, payload={})
    assert calls == ["ok"], "bolt passes events no ack, so calling one must not be attempted"


def refused_entry(monkeypatch, silent_refusal):
    @contextlib.contextmanager
    def fake_session():
        yield object()

    audited = []
    monkeypatch.setattr(surface, "session", fake_session)
    monkeypatch.setattr(surface.audit, "record", lambda conn, *args, **kwargs: audited.append(args))
    monkeypatch.setattr(surface.access, "may", lambda conn, user_id, key: (False, "You have no Fire Department access."))
    sent = []
    monkeypatch.setattr(surface.Ctx, "post_ephemeral", lambda self, message, *args: sent.append(message))
    calls = []
    entry = surface.SurfaceEntry(surface.ACTION, "lock_notice_menu", "thread.guard",
                                 lambda ctx: calls.append("ran"), silent_refusal=silent_refusal)
    acks = []
    surface.guarded(entry)(ack=lambda **kwargs: acks.append(kwargs), body={"user": {"id": "U1"}},
                           client=None, payload={})
    return calls, acks, sent, audited


def test_guarded_refused_action_posts_refusal(monkeypatch):
    calls, acks, sent, audited = refused_entry(monkeypatch, silent_refusal=False)

    assert (calls, len(acks), sent) == ([], 1, ["You have no Fire Department access."])
    assert len(audited) == 1


def test_guarded_silent_refusal_acks_without_message(monkeypatch):
    calls, acks, sent, audited = refused_entry(monkeypatch, silent_refusal=True)

    assert (calls, len(acks), sent) == ([], 1, [])
    assert len(audited) == 1


class NoopApp:
    def __getattr__(self, _name):
        def hook(*_a, **_k):
            return lambda fn: fn

        return hook


def test_register_adds_multiple_message_event_handlers():
    handlers.register(NoopApp(), lambda *a, **k: None)
    on_message = [one for one in surface.ENTRIES
                  if one.kind == surface.EVENT and one.key == "message"]
    assert len(on_message) >= 2, "the guard watcher and the case-thread reader must both be held"
    assert any(one.tag == "handlers.on_message" for one in on_message)


def test_is_watched_before_cache_load_returns_true():
    from bot.nemo import guards

    saved_loaded, saved_watched = guards._loaded, set(guards._watched)
    try:
        guards._loaded = False
        guards._watched.clear()
        assert guards.is_watched("C_ANY", "1.1") is True, "a cold cache must defer to the database"
        guards._loaded = True
        assert guards.is_watched("C_ANY", "1.1") is False
    finally:
        guards._loaded, guards._watched = saved_loaded, saved_watched


def test_listeners_name_bolt_injected_arguments():
    import inspect

    from bot.nemo import surface as s

    for handler in (s.run_entries([]), s.guarded(s.SurfaceEntry(s.EVENT, "message", None,
                                                 lambda ctx: None, open_to_all=True))):
        named = inspect.getfullargspec(handler).args
        assert set(s.INJECTED) <= set(named), (
            f"bolt injects only named arguments, {handler} would be handed nothing: {named}"
        )


def test_channel_missing_matches_channel_errors_only():
    from bot.core import privileged

    assert privileged.channel_missing(Exception("channel_not_found"))
    assert privileged.channel_missing(Exception("not_in_channel"))
    assert not privileged.channel_missing(Exception("invalid_auth: missing_scope"))
    assert not privileged.channel_missing(Exception("message_not_found"))


def test_remove_channel_missing_invites_admin_then_retries_once():
    from bot.core import privileged
    from bot.nemo import guard_actions

    tries, invited = [], []

    def failing_delete(channel_id, ts, max_retries=2):
        tries.append(ts)
        if len(tries) == 1:
            raise RuntimeError("channel_not_found")

    class Client:
        def conversations_invite(self, channel, users):
            invited.append((channel, users))

    saved_delete, saved_admin = privileged.delete_message, privileged.admin_user_id
    try:
        privileged.delete_message = failing_delete
        privileged.admin_user_id = lambda: "UADMIN"
        guard_actions.remove(Client(), "C1", "1.1")
    finally:
        privileged.delete_message, privileged.admin_user_id = saved_delete, saved_admin

    assert invited == [("C1", "UADMIN")], "the admin must be invited before the retry"
    assert tries == ["1.1", "1.1"], "the delete is retried exactly once after the invite"
