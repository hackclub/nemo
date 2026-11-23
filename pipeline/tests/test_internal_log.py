import contextlib
import datetime as dt
import threading
from types import SimpleNamespace

import pytest

from bot.core.formatting import short_end_token
from bot.nemo import guard_actions, internal_log, loop
from bot.nemo.views.activity import message_url

END = dt.datetime(2026, 10, 17, 14, 30, tzinfo=dt.UTC)
THREAD = "1700000000.000100"
THREAD_LINK = f"<{message_url('C1', THREAD)}|thread>"


def entry(verb, actor="UMOD", before=None, after=None, entity_type="member_guard"):
    return {"id": 1, "actor": actor, "entity_type": entity_type, "entity_id": 7, "verb": verb,
            "before": before, "after": after}


SHUSH = ("shush", "U1", None, "spam", END, None)
BAN = ("channel_ban", "U1", "C1", "spam", None, None)


@pytest.mark.parametrize(("row", "made", "line"), [
    (SHUSH, entry("opened"), f"<@U1> shushed until {short_end_token(END)} for *spam* by <@UMOD>"),
    (BAN, entry("opened"), "<@U1> banned from <#C1> with no end date for *spam* by <@UMOD>"),
    (SHUSH, entry("extended"), f"<@U1> shush extended to {short_end_token(END)} by <@UMOD>"),
    (SHUSH, entry("lifted", after={"lift_reason": "appeal upheld"}),
     "Shush lifted for <@U1> for *appeal upheld* by <@UMOD>"),
    (BAN, entry("lifted", actor="nemo", after={"lift_reason": internal_log.EXPIRED_REASON}),
     "Channel ban ended for <@U1> from <#C1>"),
    (SHUSH, entry("attached"), None),
])
def test_member_line_formats_guard_change_per_verb(row, made, line):
    assert internal_log.member_line(made, row) == line


SLOW = ("slowmode", "C1", "", {"seconds": 30, "threads": True}, "Heated", END)
THREAD_SLOW = ("slowmode", "C1", THREAD, {"seconds": 120}, "Heated", None)
GATE = ("account_age", "C1", "", {"min_age_days": 7}, None, None)


@pytest.mark.parametrize(("row", "made", "line"), [
    (SLOW, entry("opened", entity_type="channel_guard"),
     f"Slow mode enabled on <#C1> with 30s cooldown until {short_end_token(END)} and threads "
     f"for *Heated* by <@UMOD>"),
    (THREAD_SLOW, entry("opened", entity_type="channel_guard"),
     f"Slow mode enabled on <#C1> {THREAD_LINK} with 2m cooldown and no end date for *Heated* by <@UMOD>"),
    (GATE, entry("opened", entity_type="channel_guard"), "New-account age enabled on <#C1> with 7 days by <@UMOD>"),
    (SLOW, entry("extended", entity_type="channel_guard"),
     f"Slow mode extended on <#C1> to {short_end_token(END)} by <@UMOD>"),
    (SLOW, entry("lifted", entity_type="channel_guard"), "Slow mode disabled on <#C1> by <@UMOD>"),
    (SLOW, entry("lifted", actor="system", entity_type="channel_guard"), "Slow mode ended on <#C1>"),
])
def test_channel_line_formats_guard_change_per_verb(row, made, line):
    assert internal_log.channel_line(made, row) == line


def test_allow_line_formats_added_and_removed_exemptions():
    added = entry("added", after={"subject_id": "U2"}, entity_type="channel_allow")
    removed = entry("removed", before={"subject_id": "B1"}, entity_type="channel_allow")
    bots = ("bot_allowlist", "C1", "", {}, None, None)

    assert internal_log.allow_line(added, SLOW) == \
        "Exemption from Slow mode added on <#C1> for <@U2> by <@UMOD>"
    assert internal_log.allow_line(removed, bots) == \
        "Bot removed from the allow list on <#C1> for <@B1> by <@UMOD>"


LOCK = ("lock", "C1", THREAD, "raid", END, "running", None)


@pytest.mark.parametrize(("row", "made", "line"), [
    (LOCK, entry("opened", entity_type="thread_guard"),
     f"Lock on <#C1> {THREAD_LINK} until {short_end_token(END)} for *raid* by <@UMOD>"),
    (LOCK, entry("extended", entity_type="thread_guard"),
     f"Lock on <#C1> {THREAD_LINK} extended to {short_end_token(END)} by <@UMOD>"),
    (LOCK[:5] + ("done", None), entry("lifted", entity_type="thread_guard"),
     f"Lock on <#C1> {THREAD_LINK} unlocked by <@UMOD>"),
    (LOCK[:5] + ("done", None), entry("lifted", actor="system", entity_type="thread_guard"),
     f"Lock on <#C1> {THREAD_LINK} ended"),
    (LOCK[:5] + ("done", internal_log.REPLACED_BY_DESTROY), entry("lifted", entity_type="thread_guard"), None),
    (LOCK[:5] + ("failed", "warning not posted"), entry("lifted", actor="system", entity_type="thread_guard"), None),
    (("destroy",) + LOCK[1:], entry("opened", entity_type="thread_guard"), None),
])
def test_thread_line_formats_lock_changes_and_returns_none_for_destroy(row, made, line):
    assert internal_log.thread_line(made, row) == line


def test_automod_line_formats_message_link_and_quote():
    match = (3, "badword", "U1", "C1", "https://hackclub.slack.com/archives/C1/p1", "a badword here")

    assert internal_log.automod_line(match) == \
        'Automod matched "badword" from <@U1> in <#C1> (<https://hackclub.slack.com/archives/C1/p1|message>)\n> a badword here'


class Conn:
    def __init__(self, entries=(), matches=(), rows=None):
        self.entries = list(entries)
        self.matches = list(matches)
        self.rows = rows or {}
        self.cursor_moves = []
        self.sql = None

    def execute(self, sql, args=None):
        self.sql, self.args = sql, args
        if sql == internal_log.MOVE_CURSOR:
            self.cursor_moves.append(args)
        return self

    def fetchone(self):
        if self.sql == internal_log.CURSOR:
            return (10,)
        return self.rows.get(self.sql)

    def fetchall(self):
        return self.entries if self.sql == internal_log.AUDIT_ENTRIES else self.matches


class Slack:
    def __init__(self, fails_on=None):
        self.fails_on = fails_on
        self.posted = []

    def chat_postMessage(self, **kwargs):
        if self.fails_on and self.fails_on in kwargs["text"]:
            raise RuntimeError("ratelimited")
        self.posted.append(kwargs)


def drain_with(monkeypatch, conn, client, log_channel="CLOGS"):
    @contextlib.contextmanager
    def session_of():
        yield conn

    monkeypatch.setattr(internal_log, "session", session_of)
    monkeypatch.setattr(internal_log.channel, "log_channel", lambda conn=None: log_channel)
    return internal_log.drain(client)


AUDIT_ROWS = [(11, "UMOD", "member_guard", 7, "opened", None, None),
              (12, "UMOD", "member_guard", 7, "attached", None, None)]


def test_drain_posts_lines_and_moves_cursor(monkeypatch):
    conn = Conn(AUDIT_ROWS, [(4, "badword", "U1", "C1", None, "")], rows={internal_log.MEMBER_GUARD: SHUSH})
    client = Slack()

    assert drain_with(monkeypatch, conn, client) == 3
    assert [one["text"].split()[0] for one in client.posted] == ["<@U1>", "Automod"]
    assert all(one["channel"] == "CLOGS" for one in client.posted)
    assert conn.cursor_moves == [(11, "audit"), (12, "audit"), (4, "automod")]


def test_drain_with_failed_post_does_not_move_cursor(monkeypatch):
    conn = Conn(AUDIT_ROWS[:1], rows={internal_log.MEMBER_GUARD: SHUSH})

    assert drain_with(monkeypatch, conn, Slack(fails_on="shushed")) == 0
    assert conn.cursor_moves == []


def test_drain_without_log_channel_moves_cursor_without_posting(monkeypatch):
    conn = Conn(AUDIT_ROWS[:1], rows={internal_log.MEMBER_GUARD: SHUSH})
    client = Slack()

    assert drain_with(monkeypatch, conn, client, log_channel=None) == 1
    assert client.posted == []
    assert conn.cursor_moves == [(11, "audit")]


def test_audit_entries_sql_has_seven_day_bound_and_entity_filter():
    assert "occurred_at > now() - interval '7 days'" in internal_log.AUDIT_ENTRIES
    assert "entity_type = ANY(%s) AND verb = ANY(%s)" in internal_log.AUDIT_ENTRIES


@pytest.fixture
def loop_listener(monkeypatch):
    wake_names = []

    @contextlib.contextmanager
    def session_of():
        yield object()

    listener = {}
    monkeypatch.setattr(loop, "session", session_of)
    for module in (loop.guards, loop.channelguards, loop.memberguards, loop.automod,
                   loop.responses, loop.screening, loop.categories):
        monkeypatch.setattr(module, "refresh", lambda conn: 0)
    monkeypatch.setattr(loop.channel, "refresh_channels", lambda conn: None)
    monkeypatch.setattr(loop.purge, "requeue_interrupted", lambda conn: [])
    monkeypatch.setattr(loop.loops, "run_on_wake", lambda name, *args, **kwargs: (lambda: wake_names.append(name)))
    monkeypatch.setattr(loop.loops, "run_on_timer", lambda *args, **kwargs: (lambda: None))
    monkeypatch.setattr(loop.loops, "run_periodically", lambda *args, **kwargs: None)
    monkeypatch.setattr(loop.loops, "start_listener", lambda name, names, on_notify, stopping:
                        listener.update(names=names, on_notify=on_notify))
    loop.start(SimpleNamespace(client=None), threading.Event())
    return listener, wake_names


@pytest.mark.parametrize(("channel_name", "payload", "wakes"), [
    (loop.AUDIT_EVENT, '{"source": "fire_engine", "actions": ["opened"]}', True),
    (loop.AUDIT_EVENT, '{"source": "slack", "actions": ["user_login"]}', False),
    (loop.AUTOMOD_MATCH, "", True),
])
def test_loop_notification_wakes_log_drain_per_payload(loop_listener, channel_name, payload, wakes):
    listener, wake_names = loop_listener

    listener["on_notify"](channel_name, payload)

    assert loop.AUDIT_EVENT in listener["names"] and loop.AUTOMOD_MATCH in listener["names"]
    assert ("nemo-log" in wake_names) is wakes


def test_post_destroy_notice_includes_message_count(monkeypatch):
    posted = []
    monkeypatch.setattr(guard_actions.channel, "log_channel", lambda conn=None: "CLOGS")
    monkeypatch.setattr(guard_actions, "archive_url", lambda channel_id, thread_ts: "https://fe/archive")
    client = SimpleNamespace(chat_postMessage=lambda **kwargs: posted.append(kwargs))

    guard_actions.post_destroy_notice(client, object(), "C1", THREAD, "UMOD", 42)

    assert posted[0]["text"] == \
        "Thread in <#C1> destroyed by <@UMOD> (42 messages, <https://fe/archive|archive>)"


def test_loop_bot_kick_notification_wakes_kick_drain(loop_listener):
    listener, wake_names = loop_listener

    listener["on_notify"](loop.BOT_KICK, "B1")

    assert loop.BOT_KICK in listener["names"]
    assert "nemo-kicks" in wake_names


EARLIER = {"expires_at": "2027-10-17 10:00:00+00:00"}
LATER = {"expires_at": "2027-10-18 10:00:00+00:00"}


@pytest.mark.parametrize(("before", "after", "word"), [
    (EARLIER, LATER, "extended"),
    (LATER, EARLIER, "shortened"),
    (None, LATER, "extended"),
    ({"expires_at": None}, LATER, "extended"),
    (EARLIER, {"expires_at": None}, "extended"),
    ({"expires_at": "not a date"}, EARLIER, "extended"),
    (EARLIER, {"expires_at": "2027-10-17T10:00:00Z"}, "extended"),
])
def test_extension_word_follows_the_direction_of_the_end(before, after, word):
    assert internal_log.extension_word(entry("extended", before=before, after=after)) == word


def test_extension_lines_say_shortened_when_the_end_moves_earlier():
    moved = {"before": LATER, "after": EARLIER}

    assert internal_log.member_line(entry("extended", **moved), SHUSH) == \
        f"<@U1> shush shortened to {short_end_token(END)} by <@UMOD>"
    assert internal_log.channel_line(entry("extended", entity_type="channel_guard", **moved), SLOW) == \
        f"Slow mode shortened on <#C1> to {short_end_token(END)} by <@UMOD>"
    assert internal_log.thread_line(entry("extended", entity_type="thread_guard", **moved), LOCK) == \
        f"Lock on <#C1> {THREAD_LINK} shortened to {short_end_token(END)} by <@UMOD>"


@pytest.mark.parametrize(("row", "made", "line"), [
    (("U1", "nsfw pfp"), entry("performed", entity_type="member_photo"), "Pfp removed for <@U1> for *nsfw pfp* by <@UMOD>"),
    (("U1", None), entry("performed", entity_type="member_photo"), "Pfp removed for <@U1> by <@UMOD>"),
    (("U1", "nsfw pfp"), entry("queued", entity_type="member_photo"), None),
])
def test_photo_line_formats_a_finished_removal_only(row, made, line):
    assert internal_log.photo_line(made, row) == line


def test_audit_lines_include_pfp_removals_by_type_and_verb():
    assert "member_photo" in internal_log.ENTITY_TYPES
    assert "performed" in internal_log.VERBS
    assert internal_log.LINE_BUILDERS["member_photo"][1] is internal_log.photo_line
