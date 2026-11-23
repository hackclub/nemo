import contextlib

import pytest

from bot.core import privileged
from bot.nemo import publicize

CHANNEL = "C1"
USER = "U1"


class Proxy:
    def __init__(self, info=None, managers=(), fail=(), found=()):
        self.info = info
        self.found = list(found)
        self.managers = list(managers)
        self.fail = set(fail)
        self.calls = []

    def call(self, method, params, **_):
        self.calls.append(method)
        if method in self.fail:
            raise RuntimeError(f"{method} failed: channel_not_found")
        if method == "conversations.info":
            return {"channel": self.info}
        if method == "admin.conversations.search":
            return {"conversations": self.found}
        if method == "admin.roles.entity.listAssignments":
            return {"role_assignments": [{"role_id": publicize.CHANNEL_MANAGER_ROLE, "users": self.managers}]}
        return {"ok": True}


@pytest.fixture
def setup(monkeypatch):
    audited = []

    @contextlib.contextmanager
    def session():
        yield None

    def build(info=None, managers=(), admin=False, fail=(), found=()):
        proxy = Proxy(info, managers, fail, found)
        monkeypatch.setattr(privileged, "proxy", lambda: proxy)
        monkeypatch.setattr(privileged, "profile", lambda user_id: {"is_admin": admin})
        monkeypatch.setattr(publicize, "session", session)
        monkeypatch.setattr(publicize.audit, "record", lambda *args, **kwargs: audited.append(args))
        return proxy, audited

    return build


def converted(proxy):
    return "admin.conversations.convertToPublic" in proxy.calls


def test_already_public_does_nothing(setup):
    proxy, _ = setup(info={"is_private": False})
    assert publicize.publicize(USER, CHANNEL) == publicize.ALREADY_PUBLIC
    assert not converted(proxy)


def test_admin_converts_and_is_audited(setup):
    proxy, audited = setup(info={"is_private": True}, admin=True)
    assert publicize.publicize(USER, CHANNEL) == publicize.DONE
    assert converted(proxy)
    assert audited[0][1:5] == ("channel", 0, "publicized", USER)


def test_channel_manager_converts(setup):
    proxy, _ = setup(info={"is_private": True, "creator": "U2"}, managers=[USER])
    assert publicize.publicize(USER, CHANNEL) == publicize.DONE
    assert converted(proxy)


def test_creator_refused_when_channel_has_other_managers(setup):
    proxy, _ = setup(info={"is_private": True, "creator": USER}, managers=["U2"])
    assert publicize.publicize(USER, CHANNEL) == publicize.REFUSED
    assert not converted(proxy)


def test_creator_converts_when_no_managers(setup):
    proxy, _ = setup(info={"is_private": True, "creator": USER})
    assert publicize.publicize(USER, CHANNEL) == publicize.DONE


def test_member_refused(setup):
    proxy, _ = setup(info={"is_private": True, "creator": "U2"})
    assert publicize.publicize(USER, CHANNEL) == publicize.REFUSED
    assert not converted(proxy)


def test_unreadable_channel_uses_admin_search_for_creator(setup):
    found = [{"id": "C9", "is_private": True, "creator_id": "U9"},
             {"id": CHANNEL, "is_private": True, "creator_id": USER}]
    proxy, _ = setup(fail={"conversations.info"}, found=found)
    assert publicize.publicize(USER, CHANNEL) == publicize.DONE
    assert converted(proxy)


def test_unreadable_public_channel_found_by_admin_search(setup):
    proxy, _ = setup(fail={"conversations.info"}, found=[{"id": CHANNEL, "is_private": False}])
    assert publicize.publicize(USER, CHANNEL) == publicize.ALREADY_PUBLIC
    assert not converted(proxy)


def test_unsearchable_channel_is_treated_as_private(setup):
    proxy, _ = setup(admin=True, fail={"conversations.info", "admin.conversations.search"})
    assert publicize.publicize(USER, CHANNEL) == publicize.DONE
    assert converted(proxy)


def test_convert_failure_is_reported(setup):
    _, audited = setup(info={"is_private": True}, admin=True, fail={"admin.conversations.convertToPublic"})
    assert publicize.publicize(USER, CHANNEL) == publicize.FAILED
    assert not audited
