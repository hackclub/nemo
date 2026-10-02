import pytest

from bot.nemo import channelguards
from bot.nemo.carriers import account_age, readonly, slowmode

WHO = "U1"
ROOM = "C1"
TS = "1700000000.000100"
THREAD = "1700000000.000000"


class Conn:
    def __init__(self, tick=None, left=None, joined=True):
        self.tick = tick
        self.left = left
        self.joined = joined
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        sql, _ = self.ran[-1]
        if "INSERT INTO fd.slowmode_clock" in sql:
            return self.tick
        if "FROM fd.slowmode_clock" in sql:
            return (self.left,) if self.left is not None else None
        if "INSERT INTO fd.member_joins" in sql:
            return (WHO,) if self.joined else None
        if "fd.member_joins" in sql:
            return (self.left,) if self.left is not None else None
        return (1,)

    def fetchall(self):
        return []

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class Slack:
    def __init__(self):
        self.ephemeral = []

    def chat_postEphemeral(self, **kwargs):
        self.ephemeral.append(kwargs)
        return {"ok": True}


class Ctx:
    def __init__(self, event, client=None):
        self.payload = event
        self.client = client or Slack()


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False


def said(text="a message", **over):
    return {"user": WHO, "channel": ROOM, "ts": TS, "text": text, **over}


@pytest.fixture(autouse=True)
def clean():
    channelguards._held.clear()
    channelguards._loaded = False
    yield
    channelguards._held.clear()
    channelguards._loaded = False


def guard(kind, settings=None, allowed=()):
    channelguards._held[(kind, ROOM)] = channelguards.Held(7, settings or {}, frozenset(allowed))
    channelguards._loaded = True


def wire(monkeypatch, module, conn, removes=True):
    monkeypatch.setattr(module, "session", lambda: _held(conn))
    taken = []

    def remove(_client, channel_id, ts):
        if not removes:
            raise RuntimeError("could not remove")
        taken.append((channel_id, ts))
        return True

    monkeypatch.setattr(module.guardwork, "remove", remove)
    return taken


def test_nothing_is_read_before_the_cache_is_loaded():
    assert channelguards.guarding(ROOM, channelguards.READONLY) is None
    assert channelguards.lets_past(ROOM, WHO, kind=channelguards.READONLY)


def test_readonly_removes_a_top_level_message(monkeypatch):
    guard(channelguards.READONLY)
    conn = Conn()
    taken = wire(monkeypatch, readonly, conn)
    client = Slack()

    assert readonly.seen(Ctx(said(), client)) is True
    assert taken == [(ROOM, TS)]
    assert conn.did("INSERT INTO fd.channel_guard_events")


def test_readonly_echoes_the_message_back(monkeypatch):
    guard(channelguards.READONLY)
    client = Slack()
    wire(monkeypatch, readonly, Conn())
    readonly.seen(Ctx(said("the thing I typed"), client))

    assert "the thing I typed" in client.ephemeral[0]["text"]


def test_readonly_leaves_a_thread_reply_alone(monkeypatch):
    guard(channelguards.READONLY)
    conn = Conn()
    taken = wire(monkeypatch, readonly, conn)

    assert readonly.seen(Ctx(said(thread_ts=THREAD))) is None
    assert taken == []


def test_readonly_catches_a_thread_broadcast(monkeypatch):
    guard(channelguards.READONLY)
    taken = wire(monkeypatch, readonly, Conn())
    readonly.seen(Ctx(said(thread_ts=THREAD, subtype="thread_broadcast")))

    assert taken == [(ROOM, TS)]


def test_readonly_lets_an_allowed_member_post(monkeypatch):
    guard(channelguards.READONLY, allowed=[WHO])
    taken = wire(monkeypatch, readonly, Conn())

    assert readonly.seen(Ctx(said())) is None
    assert taken == []


def test_readonly_records_nothing_when_the_removal_fails(monkeypatch):
    guard(channelguards.READONLY)
    conn = Conn()
    wire(monkeypatch, readonly, conn, removes=False)

    assert readonly.seen(Ctx(said())) is None
    assert not conn.did("INSERT INTO fd.channel_guard_events")


def test_slowmode_lets_the_first_message_through(monkeypatch):
    guard(channelguards.SLOWMODE, {"seconds": 30})
    conn = Conn(tick=("now",))
    taken = wire(monkeypatch, slowmode, conn)

    assert slowmode.seen(Ctx(said())) is None
    assert taken == []


def test_slowmode_removes_one_that_is_too_soon(monkeypatch):
    guard(channelguards.SLOWMODE, {"seconds": 30})
    conn = Conn(tick=None, left=12)
    taken = wire(monkeypatch, slowmode, conn)
    client = Slack()

    assert slowmode.seen(Ctx(said(), client)) is True
    assert taken == [(ROOM, TS)]
    assert "12 seconds" in client.ephemeral[0]["text"]


def test_slowmode_skips_threads_unless_it_is_told_to(monkeypatch):
    guard(channelguards.SLOWMODE, {"seconds": 30})
    taken = wire(monkeypatch, slowmode, Conn(tick=None, left=5))

    assert slowmode.seen(Ctx(said(thread_ts=THREAD))) is None
    assert taken == []


def test_slowmode_keys_a_thread_on_its_own_clock(monkeypatch):
    guard(channelguards.SLOWMODE, {"seconds": 30, "threads": True})
    conn = Conn(tick=None, left=5)
    wire(monkeypatch, slowmode, conn)
    slowmode.seen(Ctx(said(thread_ts=THREAD)))

    assert conn.did("INSERT INTO fd.slowmode_clock")[0][1] == THREAD


def test_slowmode_keys_a_channel_message_on_the_empty_thread(monkeypatch):
    guard(channelguards.SLOWMODE, {"seconds": 30})
    conn = Conn(tick=("now",))
    wire(monkeypatch, slowmode, conn)
    slowmode.seen(Ctx(said()))

    assert conn.did("INSERT INTO fd.slowmode_clock")[0][1] == ""


def test_slowmode_lets_an_exempt_member_post(monkeypatch):
    guard(channelguards.SLOWMODE, {"seconds": 30}, allowed=[WHO])
    taken = wire(monkeypatch, slowmode, Conn(tick=None, left=5))

    assert slowmode.seen(Ctx(said())) is None
    assert taken == []


def test_slowmode_with_no_interval_does_nothing(monkeypatch):
    guard(channelguards.SLOWMODE, {"seconds": 0})
    taken = wire(monkeypatch, slowmode, Conn(tick=None, left=5))

    assert slowmode.seen(Ctx(said())) is None
    assert taken == []


def test_the_wait_reads_in_minutes_once_it_is_long():
    assert slowmode.said_left(45) == "45 seconds"
    assert slowmode.said_left(1) == "1 second"
    assert slowmode.said_left(90) == "2 minutes"


def test_account_age_removes_a_member_who_is_too_new(monkeypatch):
    guard(channelguards.ACCOUNT_AGE, {"min_age_days": 7})
    conn = Conn(left=3)
    taken = wire(monkeypatch, account_age, conn)
    client = Slack()

    assert account_age.seen(Ctx(said(), client)) is True
    assert taken == [(ROOM, TS)]
    assert "3 days" in client.ephemeral[0]["text"]


def test_account_age_lets_an_old_enough_member_post(monkeypatch):
    guard(channelguards.ACCOUNT_AGE, {"min_age_days": 7})
    taken = wire(monkeypatch, account_age, Conn(left=None))

    assert account_age.seen(Ctx(said())) is None
    assert taken == []


def test_account_age_lets_a_member_we_never_saw_join_post(monkeypatch):
    guard(channelguards.ACCOUNT_AGE, {"min_age_days": 7})
    taken = wire(monkeypatch, account_age, Conn(left=None))

    assert account_age.seen(Ctx(said())) is None
    assert taken == []


def test_account_age_lets_an_exempt_member_post(monkeypatch):
    guard(channelguards.ACCOUNT_AGE, {"min_age_days": 7}, allowed=[WHO])
    taken = wire(monkeypatch, account_age, Conn(left=3))

    assert account_age.seen(Ctx(said())) is None
    assert taken == []


def test_a_join_is_recorded(monkeypatch):
    conn = Conn()
    monkeypatch.setattr(account_age, "session", lambda: _held(conn))

    assert account_age.arrived(Ctx({"user": {"id": WHO}})) == WHO
    assert conn.did("INSERT INTO fd.member_joins")


def test_a_join_without_an_id_is_ignored(monkeypatch):
    conn = Conn()
    monkeypatch.setattr(account_age, "session", lambda: _held(conn))

    assert account_age.arrived(Ctx({"user": {}})) is None
    assert not conn.did("INSERT INTO fd.member_joins")


def test_a_carrier_ignores_a_bot(monkeypatch):
    guard(channelguards.READONLY)
    taken = wire(monkeypatch, readonly, Conn())

    assert readonly.seen(Ctx(said(bot_id="B1"))) is None
    assert taken == []


def test_a_carrier_ignores_a_direct_message(monkeypatch):
    guard(channelguards.READONLY)
    channelguards._held[(channelguards.READONLY, "D1")] = channelguards.Held(7, {}, frozenset())
    taken = wire(monkeypatch, readonly, Conn())

    assert readonly.seen(Ctx(said(channel="D1"))) is None
    assert taken == []


def test_kinds_do_not_read_each_others_guards():
    guard(channelguards.READONLY)

    assert channelguards.guarding(ROOM, channelguards.SLOWMODE) is None
    assert channelguards.guarding(ROOM, channelguards.READONLY) is not None


def test_account_age_falls_back_to_when_the_account_was_claimed():
    sql = account_age.DAYS_LEFT

    assert "fd.member_joins" in sql
    assert "analytics.dim_member" in sql
    assert "coalesce(j.joined_at, m.claimed_at)" in sql, "a join event must win over the warehouse"


def test_account_age_asks_nothing_of_a_member_neither_source_knows():
    sql = account_age.DAYS_LEFT

    assert "WHERE known.at IS NOT NULL" in sql, "an unknown member yields no row, so the gate opens"
