import random
from datetime import date, datetime, time, timedelta, timezone

from seed import spine


def at(day, hour):
    return datetime.combine(day, time(hour, 0), tzinfo=timezone.utc)


def message(day, hour, author, channel="CSEED1"):
    when = at(day, hour)
    return spine.Message(channel, spine.stamp(when), when, author, False, 0)


DAY = date(2026, 8, 1)


def always():
    rng = random.Random()
    rng.random = lambda: 0.0
    return rng


def never():
    rng = random.Random()
    rng.random = lambda: 1.0
    return rng


def test_a_reply_never_attaches_to_its_own_author():
    made = [message(DAY, 9, "USEED1"), message(DAY, 10, "USEED1")]
    spine.thread_them(always(), made)

    assert not made[1].is_reply, "a lone author talking to themselves is not a thread"


def test_a_reply_attaches_to_somebody_else():
    made = [message(DAY, 9, "USEED1"), message(DAY, 10, "USEED2")]
    spine.thread_them(always(), made)

    assert made[1].is_reply
    assert made[1].root_ts == made[0].ts
    assert made[0].reply_count == 1
    assert made[0].repliers == {"USEED2"}


def test_nothing_attaches_beyond_the_reply_window():
    late = DAY + timedelta(days=spine.REPLY_WINDOW_SECONDS // 86400 + 3)
    made = [message(DAY, 9, "USEED1"), message(late, 9, "USEED2")]
    spine.thread_them(always(), made)

    assert not made[1].is_reply, "a message days later is a new conversation"


def test_a_quiet_channel_makes_no_threads():
    made = [message(DAY, 9, "USEED1"), message(DAY, 10, "USEED2")]
    spine.thread_them(never(), made)

    assert [m for m in made if m.is_reply] == []
    assert list(spine.thread_rows(made, at(DAY, 12))) == []


def test_a_thread_row_counts_distinct_repliers_not_replies():
    made = [
        message(DAY, 9, "USEED1"),
        message(DAY, 10, "USEED2"),
        message(DAY, 11, "USEED2"),
    ]
    spine.thread_them(always(), made)
    rows = list(spine.thread_rows(made, at(DAY, 12)))

    assert len(rows) == 1
    _channel, _root, reply_count, repliers, latest = rows[0][:5]
    assert reply_count == 2
    assert repliers == 1
    assert latest == made[2].ts


def test_only_recent_messages_arrive_by_both_transports():
    old, new = message(DAY, 9, "USEED1"), message(DAY + timedelta(days=30), 9, "USEED2")
    cutoff = at(DAY + timedelta(days=20), 0)
    rows = list(spine.observation_rows([old, new], cutoff, at(DAY, 12)))

    assert [row[2] for row in rows if row[1] == old.ts] == [spine.TRANSPORT]
    assert [row[2] for row in rows if row[1] == new.ts] == [
        spine.TRANSPORT,
        spine.EVENT_TRANSPORT,
    ], "a message inside the events window is seen twice, once down each path"
