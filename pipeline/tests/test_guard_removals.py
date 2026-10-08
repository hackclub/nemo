from bot.nemo import guard_removals

ROOM = "C1"


class Conn:
    def __init__(self, pending=(), still=True):
        self.pending = list(pending)
        self.still = still
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        self.last = sql
        return self

    def fetchall(self):
        return self.pending

    def fetchone(self):
        return (self.still,)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False


def throttled():
    failure = RuntimeError("proxy returned 429: budget: nemo:admin:chat.delete is spent")
    failure.http_status = 429
    return failure


def drained(monkeypatch, conn, outcomes=None, settled=None):
    tried = []
    outcomes = dict(outcomes or {})

    def remove(client, channel_id, ts, max_retries=2):
        tried.append((ts, max_retries))
        if ts in outcomes:
            raise outcomes[ts]
        return True

    monkeypatch.setattr(guard_removals, "session", lambda: _held(conn))
    monkeypatch.setattr(guard_removals.guard_actions, "remove", remove)
    more = guard_removals.drain(object(), settled)
    return tried, more


def pending(*ts):
    return [(n, ROOM, one) for n, one in enumerate(ts, start=1)]


def test_queued_deletes_are_retried_without_sleeping(monkeypatch):
    conn = Conn(pending("1.1", "1.2"))
    woke = []

    tried, more = drained(monkeypatch, conn, settled=lambda: woke.append(1))

    assert tried == [("1.1", 0), ("1.2", 0)]
    assert conn.did("SET remove_pending = false, detail = NULL") == [(1,), (2,)]
    assert woke == [1]
    assert more is False


def test_a_rate_limit_stops_the_pass_without_spending_an_attempt(monkeypatch):
    conn = Conn(pending("1.1", "1.2", "1.3"))

    tried, more = drained(monkeypatch, conn, {"1.2": throttled()})

    assert [ts for ts, _ in tried] == ["1.1", "1.2"]
    assert conn.did("SET remove_pending = false, detail = NULL") == [(1,)]
    assert not conn.did("remove_attempts = remove_attempts + 1")
    assert more is False


def test_another_failure_spends_an_attempt_and_keeps_going(monkeypatch):
    conn = Conn(pending("1.1", "1.2"), still=True)
    woke = []

    drained(monkeypatch, conn, {"1.1": RuntimeError("cant_delete_message")},
            settled=lambda: woke.append(1))

    (failed,) = conn.did("remove_attempts = remove_attempts + 1")
    assert failed == ("cant_delete_message", guard_removals.GIVE_UP_AFTER,
                      guard_removals.GIVE_UP_AFTER, 1)
    assert conn.did("SET remove_pending = false, detail = NULL") == [(2,)]
    assert woke == [1]


def test_giving_up_wakes_the_notices(monkeypatch, caplog):
    conn = Conn(pending("1.1"), still=False)
    woke = []
    caplog.set_level("WARNING", logger="bot.nemo")

    drained(monkeypatch, conn, {"1.1": RuntimeError("cant_delete_message")},
            settled=lambda: woke.append(1))

    assert woke == [1]
    assert any("gave up deleting 1.1" in one.getMessage() for one in caplog.records)


def test_a_message_already_gone_counts_as_removed(monkeypatch):
    conn = Conn(pending("1.1"))

    drained(monkeypatch, conn, {"1.1": RuntimeError("message_not_found")})

    assert conn.did("SET remove_pending = false, detail = NULL") == [(1,)]
    assert not conn.did("remove_attempts = remove_attempts + 1")


def test_nothing_pending_wakes_nothing(monkeypatch):
    woke = []

    tried, more = drained(monkeypatch, Conn(), settled=lambda: woke.append(1))

    assert tried == []
    assert woke == []
    assert more is False


def test_a_full_pass_asks_for_another(monkeypatch):
    monkeypatch.setattr(guard_removals, "PER_DRAIN", 2)

    _tried, more = drained(monkeypatch, Conn(pending("1.1", "1.2")))

    assert more is True


def test_the_claim_takes_only_queued_deletes():
    from bot.nemo import channelguards

    assert "WHERE remove_pending" in channelguards.CLAIM_REMOVALS
    assert "FOR UPDATE SKIP LOCKED" in channelguards.CLAIM_REMOVALS
