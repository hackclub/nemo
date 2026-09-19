import pytest
import yaml

from bot.nemo import app as nemo_app  # noqa: F401  registers every surface
from bot.nemo import handlers, surface
from lib.paths import CAPABILITIES_FILE

CAPABILITIES = yaml.safe_load(CAPABILITIES_FILE.read_text())["capabilities"]


def test_every_surface_names_a_capability_or_is_open():
    silent = [one for one in surface.ENTRIES if not one.open_to_all and not one.needs]
    assert silent == [], f"these write without declaring a capability: {silent}"


def test_every_named_capability_exists():
    named = {one.needs for one in surface.ENTRIES if one.needs}
    assert named <= set(CAPABILITIES), f"unknown capabilities: {named - set(CAPABILITIES)}"


def test_declared_refuses_an_undeclared_surface():
    entry = surface.Entry(surface.ACTION, "loose_button", None, lambda ctx: None)
    surface.ENTRIES.append(entry)
    try:
        with pytest.raises(surface.Undeclared):
            surface.declared()
    finally:
        surface.ENTRIES.remove(entry)


def test_the_thread_guards_are_registered():
    keys = {(one.kind, one.key) for one in surface.ENTRIES}
    assert ("shortcut", "destroy_thread") in keys
    assert ("shortcut", "lock_thread") in keys
    assert ("view", "thread_destroy") in keys
    assert ("view", "thread_lock") in keys


def test_the_message_watcher_is_open_to_everyone():
    watcher = [one for one in surface.ENTRIES if one.kind == surface.EVENT]
    assert watcher, "the guarded-thread watcher is not registered"
    assert all(one.open_to_all for one in watcher)


def test_one_key_gets_one_listener_that_runs_every_handler():
    ran = []
    entries = [
        surface.Entry(surface.EVENT, "message", None, lambda ctx: ran.append("first"),
                      open_to_all=True),
        surface.Entry(surface.EVENT, "message", None, lambda ctx: ran.append("second"),
                      open_to_all=True),
    ]
    surface.fanned(entries)(ack=None, body={}, client=None, payload={})
    assert ran == ["first", "second"], "bolt stops at the first answer, so we must fan out"


def test_one_failing_handler_does_not_silence_the_others():
    ran = []

    def angry(ctx):
        raise RuntimeError("no")

    entries = [
        surface.Entry(surface.EVENT, "message", None, angry, open_to_all=True),
        surface.Entry(surface.EVENT, "message", None, lambda ctx: ran.append("still ran"),
                      open_to_all=True),
    ]
    surface.fanned(entries)(ack=None, body={}, client=None, payload={})
    assert ran == ["still ran"], "a handler that throws must not take the others down"


def test_an_event_without_an_ack_does_not_blow_up():
    ran = []
    entry = surface.Entry(surface.EVENT, "message", None, lambda ctx: ran.append("ok"),
                          open_to_all=True)
    surface.guarded(entry)(ack=None, body={}, client=None, payload={})
    assert ran == ["ok"], "bolt passes events no ack, so calling one must not be attempted"


class Nothing:
    def __getattr__(self, _name):
        def hook(*_a, **_k):
            return lambda fn: fn

        return hook


def test_the_firehouse_and_the_guard_share_the_message_key():
    handlers.register(Nothing(), lambda *a, **k: None)
    on_message = [one for one in surface.ENTRIES
                  if one.kind == surface.EVENT and one.key == "message"]
    assert len(on_message) >= 2, "the guard watcher and the case-thread reader must both be held"
    assert any(one.tag == "handlers.on_message" for one in on_message)


def test_a_cold_guard_cache_does_not_silence_enforcement():
    from bot.nemo import guards

    was_loaded, was_watched = guards._loaded, set(guards._watched)
    try:
        guards._loaded = False
        guards._watched.clear()
        assert guards.watching("C_ANY", "1.1") is True, "a cold cache must defer to the database"
        guards._loaded = True
        assert guards.watching("C_ANY", "1.1") is False
    finally:
        guards._loaded, guards._watched = was_loaded, was_watched


def test_the_listener_names_the_arguments_bolt_injects():
    import inspect

    from bot.nemo import surface as s

    for made in (s.fanned([]), s.guarded(s.Entry(s.EVENT, "message", None,
                                                 lambda ctx: None, open_to_all=True))):
        named = inspect.getfullargspec(made).args
        assert set(s.INJECTED) <= set(named), (
            f"bolt injects only named arguments, {made} would be handed nothing: {named}"
        )


def test_a_missing_admin_is_recognised_and_a_real_failure_is_not():
    from bot.core import privileged

    assert privileged.absent(Exception("channel_not_found"))
    assert privileged.absent(Exception("not_in_channel"))
    assert not privileged.absent(Exception("invalid_auth: missing_scope"))
    assert not privileged.absent(Exception("message_not_found"))


def test_a_delete_invites_the_admin_then_retries_once():
    from bot.core import privileged
    from bot.nemo import guardwork

    tries, invited = [], []

    def flaky(channel_id, ts):
        tries.append(ts)
        if len(tries) == 1:
            raise RuntimeError("channel_not_found")

    class Client:
        def conversations_invite(self, channel, users):
            invited.append((channel, users))

    was_delete, was_who = privileged.delete_message, privileged.admin_user_id
    try:
        privileged.delete_message = flaky
        privileged.admin_user_id = lambda: "UADMIN"
        guardwork.remove(Client(), "C1", "1.1")
    finally:
        privileged.delete_message, privileged.admin_user_id = was_delete, was_who

    assert invited == [("C1", "UADMIN")], "the admin must be invited before the retry"
    assert tries == ["1.1", "1.1"], "the delete is retried exactly once after the invite"
