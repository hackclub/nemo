import datetime as dt

import pytest

from bot.nemo import memberguards
from bot.nemo.enforcement import channel_ban, shush, sweep

WHO = "U1"
ROOM = "C1"
HOUSE = "CHOUSE"
ENDS = dt.datetime(2026, 3, 10, 12, tzinfo=dt.UTC)


class Conn:
    def __init__(self, lifts=True, settings=None):
        self.lifts = lifts
        self.settings = settings or {}
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        sql, args = self.ran[-1]
        if "SET state = 'lifted'" in sql:
            return (7,) if self.lifts else None
        if "FROM fd.app_settings" in sql:
            held = self.settings.get(args[0])
            return (held,) if held is not None else None
        return (1,)

    def fetchall(self):
        return []

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]

    def executed(self, mark):
        return any(mark in sql for sql, _ in self.ran)

    def verbs(self):
        return [args[3] for args in self.did("INSERT INTO fd.member_guard_events")]


class Slack:
    def __init__(self):
        self.posted = []

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ts": "9.9"}


def guard(**over):
    row = {"id": 7, "kind": "shush", "subject_id": WHO, "channel_id": None,
           "reason": "being awful", "expires_at": ENDS, "case_id": 412}
    row.update(over)
    return row


def test_a_lift_by_hand_is_swept_only_until_it_has_been_said():
    assert "state = 'lifted'" in memberguards.LIFTED_UNTOLD
    assert "carried_by = 'nemo'" in memberguards.LIFTED_UNTOLD
    assert "e.verb = 'released'" in memberguards.LIFTED_UNTOLD


def test_somebody_whose_shush_was_lifted_in_the_dashboard_is_told(monkeypatch):
    client = Slack()
    told = []
    monkeypatch.setattr(sweep.memberguards, "lifted_untold",
                        lambda _conn, _within: [guard()])
    monkeypatch.setattr(sweep.memberguards, "record_enforcement",
                        lambda *args, **over: told.append(args[4]))
    monkeypatch.setattr(sweep, "session", lambda: FakeSession())
    monkeypatch.setattr(sweep, "notifies_member", lambda _conn: True)

    assert sweep.sweep_lifted(client) == 1
    assert told == [memberguards.RELEASED, "told"]
    assert "can post again" in client.posted[0]["text"]


class FakeSession:
    def __enter__(self):
        return Conn()

    def __exit__(self, *_):
        return False


def test_only_a_date_already_passed_is_swept():
    assert "expires_at <= now()" in memberguards.LAPSED
    assert "state = 'live'" in memberguards.LAPSED
    assert "expires_at IS NOT NULL" in memberguards.LAPSED, "endless ones never lapse"


def test_lifting_one_that_ran_out_says_why_and_tells_them():
    conn, client = Conn(), Slack()
    assert sweep.lapse(client, conn, guard())

    lifted = conn.did("SET state = 'lifted'")[0]
    assert lifted[0] == "nemo"
    assert lifted[1] == sweep.LAPSED_BECAUSE
    assert "released" in conn.verbs()
    assert "Your shush has ended" in client.posted[0]["text"]


def test_a_ban_that_ran_out_says_they_can_come_back():
    conn, client = Conn(), Slack()
    sweep.lapse(client, conn, guard(kind="channel_ban", channel_id=ROOM))
    assert f"ban from <#{ROOM}> has ended" in client.posted[0]["text"]


def test_one_somebody_lifted_first_is_left_alone():
    conn, client = Conn(lifts=False), Slack()
    assert not sweep.lapse(client, conn, guard())
    assert conn.verbs() == []
    assert client.posted == []


def test_a_kind_with_no_carrier_still_lifts():
    conn, client = Conn(), Slack()
    assert sweep.lapse(client, conn, guard(kind="deactivate"))
    assert "released" in conn.verbs()
    assert client.posted == []


def test_a_dropped_carry_waits_longer_each_time_it_fails():
    assert "least(attempts, %s) * interval '1 minute'" in memberguards.DROPPED_AWHILE
    assert memberguards.BACKOFF_CAP == 30


def test_only_what_nemo_carries_is_retried():
    assert "carried_by = 'nemo'" in memberguards.DROPPED_AWHILE
    assert "carry = 'failed'" in memberguards.DROPPED_AWHILE


def test_retrying_goes_back_through_the_carrier(monkeypatch):
    taken = []
    monkeypatch.setattr(shush, "take_up", lambda c, conn, g: taken.append(g["id"]))
    monkeypatch.setattr(memberguards, "dropped_awhile", lambda conn: [guard()])
    monkeypatch.setattr(sweep, "session", _session(Conn()))

    assert sweep.sweep_dropped(Slack()) == 1
    assert taken == [7]


def _session(conn):
    class FakeSession:
        def __enter__(self):
            return conn

        def __exit__(self, *failure):
            return False

    return lambda: FakeSession()


def test_the_nudge_names_who_what_when_and_the_case():
    line = sweep.line_about(guard())
    assert "<@U1>" in line
    assert "shush" in line
    assert "until 10 Mar" in line
    assert "(case 412)" in line


def test_a_ban_in_the_nudge_names_its_channel():
    line = sweep.line_about(guard(kind="channel_ban", channel_id=ROOM))
    assert f"channel ban in <#{ROOM}>" in line


def test_one_on_no_case_is_called_out_in_the_nudge():
    assert "on no case" in sweep.line_about(guard(case_id=None))


def test_the_nudge_goes_out_once_and_is_written_down(monkeypatch):
    conn = Conn()
    monkeypatch.setattr(memberguards, "ending_untold", lambda c, within: [guard()])
    monkeypatch.setattr(sweep.channel, "internal_log_channel", lambda c: HOUSE)
    monkeypatch.setattr(sweep, "session", _session(conn))
    client = Slack()

    assert sweep.sweep_ending(client) == 1
    assert client.posted[0]["channel"] == HOUSE
    assert "Ending soon" in client.posted[0]["text"]
    told = conn.did("INSERT INTO fd.member_guard_events")[0]
    assert told[3] == "told"
    assert told[6] == memberguards.ENDING


def test_nothing_ending_says_nothing(monkeypatch):
    monkeypatch.setattr(memberguards, "ending_untold", lambda c, within: [])
    monkeypatch.setattr(sweep.channel, "internal_log_channel", lambda c: HOUSE)
    monkeypatch.setattr(sweep, "session", _session(Conn()))
    client = Slack()

    assert sweep.sweep_ending(client) == 0
    assert client.posted == []


def test_the_same_guard_is_not_nudged_twice_in_a_day():
    assert "interval '20 hours'" in memberguards.ENDING_UNTOLD
    assert "verb = 'told'" in memberguards.ENDING_UNTOLD


@pytest.mark.parametrize("carrier", [shush, channel_ban])
def test_every_carrier_can_be_let_go(carrier):
    conn, client = Conn(), Slack()
    carrier.lift(client, conn, guard(kind=carrier.KIND, channel_id=ROOM))
    assert client.posted, f"{carrier.KIND} says nothing when it ends"


def test_the_ending_horizon_falls_back_when_it_is_not_set():
    assert sweep.expiring_soon(Conn()) == "36 hours"


def test_the_ending_horizon_is_read_from_the_setting():
    assert sweep.expiring_soon(Conn(settings={"nemo.sweep_soon_hours": "12"})) == "12 hours"


def test_an_horizon_outside_the_range_falls_back():
    assert sweep.expiring_soon(Conn(settings={"nemo.sweep_soon_hours": "0"})) == "36 hours"
    assert sweep.expiring_soon(Conn(settings={"nemo.sweep_soon_hours": "9999"})) == "36 hours"
    assert sweep.expiring_soon(Conn(settings={"nemo.sweep_soon_hours": "sideways"})) == "36 hours"


def test_the_member_is_told_unless_it_is_turned_off():
    assert sweep.notifies_member(Conn()) is True
    assert sweep.notifies_member(Conn(settings={"nemo.sweep_tells_member": "on"})) is True
    assert sweep.notifies_member(Conn(settings={"nemo.sweep_tells_member": "off"})) is False


def test_a_lapse_says_nothing_when_telling_is_off():
    conn = Conn(settings={"nemo.sweep_tells_member": "off"})
    client = Slack()
    sweep.lapse(client, conn, guard())

    assert client.posted == []
    assert "released" in conn.verbs()

