import pytest

from bot.nemo import memberguards
from bot.nemo.views import action

ROOM = "C1"
WHO = "U1"


class Conn:
    def __init__(self, rows=()):
        self.rows = list(rows)
        self.asked = []

    def execute(self, sql, args=None):
        self.asked.append((sql, args))
        return self

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


def guard(**over):
    row = {
        "id": 7, "kind": "shush", "subject_id": WHO, "channel_id": None,
        "state": "live", "carry": "held", "carried_by": "nemo", "case_id": None,
        "opened_by": "UMOD", "opened_at": None, "reason": "being awful",
        "expires_at": None,
    }
    row.update(over)
    return tuple(row[field] for field in memberguards.FIELDS)


def test_the_actions_table_says_which_kinds_nemo_can_carry():
    assert action.guard_kind("shush") == "shush"
    assert action.guard_scope("shush") == "workspace"
    assert action.guard_carry("shush") == "reactive"
    assert action.guard_kind("channel_ban") == "channel_ban"
    assert action.guard_scope("channel_ban") == "channel"


@pytest.mark.parametrize("type_key", ["warning", "locked_thread", "dm"])
def test_a_kind_without_an_enforce_block_is_a_record_only(type_key):
    assert action.guard_kind(type_key) is None
    assert action.enforce(type_key) == {}
    assert not memberguards.enforceable(type_key)


@pytest.mark.parametrize("type_key", ["temp_ban", "indef_ban", "perma_ban"])
def test_a_ban_is_carried_as_a_deactivation_on_the_account(type_key):
    assert action.guard_kind(type_key) == memberguards.DEACTIVATION
    assert action.guard_scope(type_key) == "account"
    assert action.guard_carry(type_key) == "applied"
    assert memberguards.enforceable(type_key)


def test_a_deactivation_is_never_looked_up_against_a_channel():
    conn = Conn([guard(kind=memberguards.DEACTIVATION)])
    memberguards.for_action(conn, "perma_ban", WHO, channel_id="C9")
    assert conn.asked[0][1] == (WHO, memberguards.DEACTIVATION, None)


def test_a_kind_nobody_declared_is_not_enforceable():
    assert action.guard_kind("nonsense") is None
    assert not memberguards.enforceable("nonsense")


def test_a_record_only_kind_is_never_looked_up():
    conn = Conn([guard()])
    assert memberguards.for_action(conn, "warning", WHO) is None
    assert conn.asked == []


def test_a_workspace_kind_drops_the_channel_it_was_handed():
    conn = Conn([guard()])
    memberguards.for_action(conn, "shush", WHO, channel_id=ROOM)
    assert conn.asked[0][1] == (WHO, "shush", None)


def test_a_channel_kind_keeps_its_channel():
    conn = Conn([guard(kind="channel_ban", channel_id=ROOM)])
    memberguards.for_action(conn, "channel_ban", WHO, channel_id=ROOM)
    assert conn.asked[0][1] == (WHO, "channel_ban", ROOM)


def test_a_guard_comes_back_as_something_readable():
    conn = Conn([guard(case_id=412)])
    found = memberguards.for_action(conn, "shush", WHO)
    assert found["id"] == 7
    assert found["case_id"] == 412
    assert found["reason"] == "being awful"


def test_nothing_standing_reads_as_unguarded():
    assert memberguards.reads(None) == memberguards.UNGUARDED
    assert memberguards.reads(None, 412) == memberguards.UNGUARDED


def test_a_guard_with_no_case_is_the_one_worth_adopting():
    found = memberguards.seen(guard(case_id=None))
    assert memberguards.reads(found, 412) == memberguards.ORPHANED
    assert memberguards.reads(found) == memberguards.ORPHANED


def test_a_guard_on_this_case_is_already_here():
    found = memberguards.seen(guard(case_id=412))
    assert memberguards.reads(found, 412) == memberguards.HERE


def test_a_guard_on_another_case_is_elsewhere():
    found = memberguards.seen(guard(case_id=318))
    assert memberguards.reads(found, 412) == memberguards.ELSEWHERE


def test_a_cased_guard_read_without_a_case_is_not_claimed_as_ours():
    found = memberguards.seen(guard(case_id=318))
    assert memberguards.reads(found) == memberguards.ELSEWHERE


def test_only_a_guard_still_on_counts_as_standing():
    assert "state IN ('live', 'lifting')" in memberguards.STANDING
    assert "state IN ('live', 'lifting')" in memberguards.FOR_MEMBER


def test_the_standing_lookup_matches_the_one_live_index():
    assert "coalesce(channel_id, '') = coalesce(%s, '')" in memberguards.STANDING


def test_everything_on_a_member_comes_back_oldest_first():
    conn = Conn([guard(id=1), guard(id=2, kind="channel_ban", channel_id=ROOM)])
    found = memberguards.for_member(conn, WHO)
    assert [one["id"] for one in found] == [1, 2]
    assert conn.asked[0][1] == (WHO,)
