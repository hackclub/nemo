import pytest

from lib.internal_client import InternalApiError, InternalAuthError, InternalClient


def make_client():
    return InternalClient(token="xoxc-x", cookie="xoxd-x", host="h", slack_route="E:T")


def test_missing_credentials_raise():
    with pytest.raises(InternalAuthError):
        InternalClient(token="", cookie="")


def test_call_classifies_auth_error(monkeypatch):
    client = make_client()
    monkeypatch.setattr(client, "_request", lambda *a, **k: {"ok": False, "error": "invalid_auth"})
    with pytest.raises(InternalAuthError):
        client.call("m")


def test_call_classifies_api_error(monkeypatch):
    client = make_client()
    monkeypatch.setattr(client, "_request", lambda *a, **k: {"ok": False, "error": "ratelimited"})
    with pytest.raises(InternalApiError):
        client.call("m")


def test_paginate_advances_cursor_until_num_found(monkeypatch):
    client = make_client()
    pages = [
        {"ok": True, "items": [1, 2], "next_cursor_mark": "m1", "num_found": 4},
        {"ok": True, "items": [3, 4], "next_cursor_mark": "m2", "num_found": 4},
    ]
    seen_cursors = []

    def fake_call(method, params, **kwargs):
        seen_cursors.append(params.get("cursor"))
        return pages[len(seen_cursors) - 1]

    monkeypatch.setattr(client, "call", fake_call)
    got = list(client.paginate("m", {}, "items", page_size=2))

    assert got == [1, 2, 3, 4]
    assert seen_cursors == [None, "m1"]
