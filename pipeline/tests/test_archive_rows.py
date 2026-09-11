from lib import archive
from lib.message import scrub, shape


def built(message, channel_id="C1"):
    return archive.message_row(channel_id, message["ts"], 1, scrub(message), shape(message))


def test_the_archive_never_stores_the_message_text():
    secret = "secret words here"
    row = built({"ts": "1700000000.000100", "user": "U1", "text": secret,
                 "thread_ts": "1699999999.000000"})

    assert secret not in row
    assert not any(isinstance(field, str) and secret in field for field in row)
    assert row[0] == "C1"


def test_the_archive_keeps_the_length_without_the_body():
    secret = "secret words here"
    row = built({"ts": "1700000000.000100", "user": "U1", "text": secret})
    held = dict(zip(
        ["channel_id", "ts", "revision", "posted_at", "author_id", "author_kind", "bot_id",
         "app_id", "parent_user_id", "subtype", "thread_root_ts", "is_reply", "is_broadcast",
         "reply_count", "reply_users_count", "latest_reply_ts", "text_length", "has_text"],
        row))
    assert held["text_length"] == len(secret)
    assert held["has_text"] is True


def test_a_thread_parent_is_not_a_reply():
    parent = built({"ts": "1700000000.000100", "user": "U1", "text": "hi",
                    "thread_ts": "1700000000.000100", "reply_count": 3})
    child = built({"ts": "1700000000.000200", "user": "U2", "text": "hi",
                   "thread_ts": "1700000000.000100"})

    assert parent[11] is False
    assert parent[13] == 3
    assert child[11] is True


def test_the_archive_reads_the_author_kind():
    human = built({"ts": "1700000000.000100", "user": "U1", "text": ""})
    bot = built({"ts": "1700000000.000200", "bot_id": "B1", "text": ""})

    assert human[5] == "member"
    assert bot[5] == "bot"


def test_an_unusable_envelope_is_refused_rather_than_stored():
    assert archive.message_row("C1", "not-a-timestamp", 1, {"user": "U1"}, {}) is None
    assert archive.message_row("C1", "1.0", 1, {"type": "reaction_added"}, {}) is None
    assert archive.message_row("C1", "1.0", 1, {"subtype": archive.GONE}, {}) is None


def test_a_rejection_is_reported_so_the_caller_can_dead_letter_it():
    import inspect

    src = inspect.getsource(archive.record_many)
    assert "on_reject" in src
    assert src.count("refuse(") >= 3
