import contextlib
import hashlib

import pytest

from bot.core import privileged
from bot.nemo import photo_removals

MEMBER_ID = "U1"
ASKED_BY = "UMGR"
IMAGE = b"\x89PNG-original"
CUSTOM_URL = "https://avatars.slack-edge.com/2026-11-23/1_hash_original.png"
CUSTOM_PROFILE = {"avatar_hash": "abc123", "image_original": CUSTOM_URL, "image_512": "https://avatars.slack-edge.com/512.png"}


class Conn:
    def __init__(self, claim=None, ready=()):
        self.claim = claim
        self.ready = list(ready)
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        self.last = sql
        return self

    def fetchone(self):
        return self.claim if self.last == photo_removals.CLAIM else None

    def fetchall(self):
        return [(one,) for one in self.ready] if self.last == photo_removals.READY else []

    def args_for(self, sql):
        return [args for one, args in self.executed if one == sql]


@pytest.fixture
def conn(monkeypatch):
    holder = Conn()

    @contextlib.contextmanager
    def session_of():
        yield holder

    monkeypatch.setattr(photo_removals, "session", session_of)
    return holder


@pytest.fixture
def slack(monkeypatch):
    state = {"profile": {"profile": dict(CUSTOM_PROFILE)}, "outcome": privileged.PHOTO_REPLACED,
             "replaced": [], "fetched": [], "refreshed": [], "audited": [], "fetch_failure": None}

    def fetch_image(url):
        state["fetched"].append(url)
        if state["fetch_failure"]:
            raise state["fetch_failure"]
        return IMAGE, "image/png"

    monkeypatch.setattr(privileged, "profile", lambda user_id: state["profile"])
    monkeypatch.setattr(privileged, "replace_photo",
                        lambda user_id: state["replaced"].append(user_id) or state["outcome"])
    monkeypatch.setattr(photo_removals, "fetch_image", fetch_image)
    monkeypatch.setattr(photo_removals, "refresh_member",
                        lambda member_id, previous_hash: state["refreshed"].append((member_id, previous_hash)))
    monkeypatch.setattr(photo_removals.audit, "record",
                        lambda *args, **kwargs: state["audited"].append((args[1:], kwargs)))
    return state


def removal(attempts=1):
    return photo_removals.Removal(5, MEMBER_ID, ASKED_BY, attempts)


@pytest.mark.parametrize("url", [
    "https://avatars.slack-edge.com/a.png",
    "https://a.slack-edge.com/df10d/img/avatars/ava_0000-512.png",
    "https://secure.gravatar.com/avatar/abc.jpg?s=512",
])
def test_allowed_image_url_accepts_slack_and_gravatar_hosts(url):
    assert photo_removals.allowed_image_url(url)


@pytest.mark.parametrize("url", [
    None,
    "",
    "http://avatars.slack-edge.com/a.png",
    "https://evil.example/a.png",
    "https://avatars.slack-edge.com.evil.example/a.png",
    "https://user@avatars.slack-edge.com/a.png",
    "https://avatars.slack-edge.com:8443/a.png",
    "file:///etc/passwd",
])
def test_allowed_image_url_rejects_other_hosts_schemes_and_authority(url):
    assert not photo_removals.allowed_image_url(url)


def test_fetch_image_disallowed_host_raises_before_any_request():
    with pytest.raises(ValueError, match="not allowed"):
        photo_removals.fetch_image("https://evil.example/a.png")


def test_redirect_to_disallowed_host_raises():
    handler = photo_removals.AllowedRedirects()

    with pytest.raises(ValueError, match="not allowed"):
        handler.redirect_request(None, None, 302, "Found", {}, "https://evil.example/a.png")


@pytest.mark.parametrize(("header", "expected"), [
    ("image/png", "image/png"),
    ("image/JPEG; charset=binary", "image/jpeg"),
    ("text/html", photo_removals.FALLBACK_TYPE),
    (None, photo_removals.FALLBACK_TYPE),
])
def test_content_type_of_keeps_image_types_only(header, expected):
    assert photo_removals.content_type_of(header) == expected


def test_image_url_prefers_the_largest_available_image():
    assert photo_removals.image_url({"image_512": "b", "image_original": "a", "image_1024": "c"}) == "a"
    assert photo_removals.image_url({"image_512": "b", "image_192": "d"}) == "b"
    assert photo_removals.image_url({}) is None


def test_original_of_profile_without_image_has_no_evidence():
    original = photo_removals.original_of({"avatar_hash": "g1"})

    assert original == photo_removals.Original(None, "g1", None, None)


def test_save_original_stores_image_with_sha256(conn):
    original = photo_removals.Original(CUSTOM_URL, "abc123", IMAGE, "image/png")

    photo_removals.save_original(5, original)

    assert conn.args_for(photo_removals.RECORD_ORIGINAL) == [(CUSTOM_URL, "abc123", 5)]
    assert conn.args_for(photo_removals.STORE_EVIDENCE) == [
        (5, IMAGE, "image/png", hashlib.sha256(IMAGE).hexdigest())]


def test_save_original_without_image_stores_no_evidence(conn):
    photo_removals.save_original(5, photo_removals.Original(None, "g1", None, None))

    assert conn.args_for(photo_removals.STORE_EVIDENCE) == []
    assert conn.args_for(photo_removals.RECORD_ORIGINAL) == [(None, "g1", 5)]


def test_perform_saves_the_original_before_replacing_it(conn, slack):
    assert photo_removals.perform(removal()) is None

    assert slack["fetched"] == [CUSTOM_URL]
    assert conn.args_for(photo_removals.STORE_EVIDENCE)
    assert slack["replaced"] == [MEMBER_ID]
    assert slack["refreshed"] == [(MEMBER_ID, "abc123")]


def test_perform_original_not_saved_leaves_the_photo_alone(conn, slack):
    slack["fetch_failure"] = OSError("timed out")

    error = photo_removals.perform(removal())

    assert error.startswith("original not saved")
    assert slack["replaced"] == []
    assert conn.args_for(photo_removals.STORE_EVIDENCE) == []


def test_perform_profile_lookup_failure_leaves_the_photo_alone(conn, slack):
    slack["profile"] = None

    assert photo_removals.perform(removal()) == "profile lookup failed"
    assert slack["replaced"] == []


def test_perform_replace_failure_returns_the_outcome_without_refresh(conn, slack):
    slack["outcome"] = "failed: ratelimited"

    assert photo_removals.perform(removal()) == "failed: ratelimited"
    assert slack["refreshed"] == []


def test_perform_default_avatar_member_is_still_replaced(conn, slack):
    slack["profile"] = {"profile": {"avatar_hash": "g1"}}

    assert photo_removals.perform(removal()) is None
    assert slack["replaced"] == [MEMBER_ID]
    assert conn.args_for(photo_removals.STORE_EVIDENCE) == []


def test_run_success_finishes_and_audits_as_the_requester(conn, slack):
    conn.claim = (5, MEMBER_ID, ASKED_BY, 1)

    assert photo_removals.run(5)

    assert conn.args_for(photo_removals.FINISH) == [(photo_removals.DONE, None, 5)]
    (args, kwargs), = slack["audited"]
    assert args == (photo_removals.ENTITY_TYPE, 5, "performed", ASKED_BY)
    assert kwargs["subject_user_id"] == MEMBER_ID


def test_run_nothing_to_claim_does_nothing(conn, slack):
    assert not photo_removals.run(5)
    assert slack["replaced"] == []
    assert conn.args_for(photo_removals.FINISH) == []


@pytest.mark.parametrize(("attempts", "sql", "args"), [
    (1, photo_removals.RETRY, ("failed: boom", 5)),
    (photo_removals.GIVE_UP_AFTER, photo_removals.FINISH, (photo_removals.FAILED, "failed: boom", 5)),
])
def test_run_failure_retries_until_attempts_are_used(conn, slack, attempts, sql, args):
    conn.claim = (5, MEMBER_ID, ASKED_BY, attempts)
    slack["outcome"] = "failed: boom"

    assert not photo_removals.run(5)

    assert conn.args_for(sql) == [args]
    assert slack["audited"] == []


def test_run_unexpected_exception_is_recorded_as_failure(conn, slack, monkeypatch):
    conn.claim = (5, MEMBER_ID, ASKED_BY, photo_removals.GIVE_UP_AFTER)
    monkeypatch.setattr(photo_removals, "perform", lambda one: (_ for _ in ()).throw(RuntimeError("bug")))

    assert not photo_removals.run(5)

    assert conn.args_for(photo_removals.FINISH) == [(photo_removals.FAILED, "failed: bug", 5)]


def test_drain_requeues_interrupted_fails_cancelled_guards_then_runs_ready_removals(conn, slack, monkeypatch):
    conn.ready = [5, 6]
    ran = []
    monkeypatch.setattr(photo_removals, "run", lambda removal_id: ran.append(removal_id) or removal_id == 5)

    assert photo_removals.drain() == 1

    assert conn.args_for(photo_removals.INTERRUPTED) == [None]
    assert conn.args_for(photo_removals.CANCELLED) == [(photo_removals.DEACTIVATION_CANCELLED,)]
    assert conn.args_for(photo_removals.READY) == [(photo_removals.PER_PASS,)]
    assert ran == [5, 6]


def test_drain_while_another_drain_runs_returns_zero(conn, slack):
    assert photo_removals._lock.acquire(blocking=False)
    try:
        assert photo_removals.drain() == 0
        assert conn.executed == []
    finally:
        photo_removals._lock.release()
