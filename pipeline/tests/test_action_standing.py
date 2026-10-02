import datetime as dt

from bot.nemo import memberguards
from bot.nemo.cards import action

ROOM = "C1"
WHO = "U1"
MOD = "UMOD"
OPENED = dt.datetime(2026, 3, 3, 12, tzinfo=dt.UTC)
ENDS = dt.datetime(2026, 3, 10, 12, tzinfo=dt.UTC)


class Conn:
    def __init__(self, rows=()):
        self.rows = list(rows)
        self.asked = []

    def execute(self, sql, args=None):
        self.asked.append((sql, args))
        return self

    def fetchone(self):
        return self.rows[0] if self.rows else None


def guard(**over):
    row = {
        "id": 7, "kind": "shush", "subject_id": WHO, "channel_id": None,
        "state": "live", "carry": "held", "carried_by": "nemo", "case_id": None,
        "opened_by": MOD, "opened_at": OPENED, "reason": "being awful",
        "expires_at": ENDS,
    }
    row.update(over)
    return row


def ids(built):
    return [one.get("block_id") for one in built]


def words(built):
    said = []
    for one in built:
        if one.get("type") == "section":
            said.append(one["text"]["text"])
        if one.get("type") == "context":
            said += [bit.get("text", "") for bit in one["elements"]]
    return "\n".join(said)


def standing(found, case_id=412, enforceable=True):
    return {"enforceable": enforceable, "found": found, "case_id": case_id,
            "reads": memberguards.reads(found, case_id)}


def test_a_modal_with_nothing_standing_grows_no_warning():
    built = action.blocks(412, {"type_key": "shush", "target_user_id": WHO},
                          standing(None))
    assert action.STANDING not in ids(built)


def test_a_record_only_kind_never_grows_a_warning():
    built = action.blocks(412, {"type_key": "warning", "target_user_id": WHO}, None)
    assert action.STANDING not in ids(built)


def test_an_orphaned_guard_says_it_sits_on_no_case():
    built = action.blocks(412, {"type_key": "shush"}, standing(guard()))
    assert action.STANDING in ids(built)
    said = words(built)
    assert f"<@{WHO}> is already shush on no case" in said
    assert f"opened by <@{MOD}>" in said
    assert "since 3 Mar" in said
    assert "until 10 Mar" in said


def test_a_guard_on_another_case_names_that_case():
    built = action.blocks(412, {"type_key": "shush"}, standing(guard(case_id=318)))
    assert "under *case 318*" in words(built)


def test_a_guard_on_this_case_says_so():
    built = action.blocks(412, {"type_key": "shush"}, standing(guard(case_id=412)))
    assert "on this case" in words(built)


def test_a_channel_guard_names_its_channel():
    found = guard(kind="channel_ban", channel_id=ROOM)
    built = action.blocks(412, {"type_key": "channel_ban"}, standing(found))
    assert f"channel ban in <#{ROOM}>" in words(built)


def test_a_guard_with_no_end_date_says_that_instead():
    built = action.blocks(412, {"type_key": "shush"}, standing(guard(expires_at=None)))
    assert "with no end date" in words(built)
    assert "until" not in words(built)


def test_a_guard_nemo_has_not_carried_admits_it():
    built = action.blocks(412, {"type_key": "shush"}, standing(guard(carry="pending")))
    assert "nemo has not carried it yet" in words(built)


def test_a_guard_nemo_has_dropped_admits_it():
    built = action.blocks(412, {"type_key": "shush"}, standing(guard(carry="failed")))
    assert "nemo is not holding it" in words(built)


def test_a_guard_done_by_hand_is_not_blamed_on_nemo():
    found = guard(carried_by="by_hand", carry="held")
    said = words(action.blocks(412, {"type_key": "shush"}, standing(found)))
    assert "done by hand" in said
    assert "nemo" not in said


def test_the_warning_sits_above_the_date_it_is_about():
    built = action.blocks(412, {"type_key": "shush"}, standing(guard()))
    shown = ids(built)
    assert shown.index(action.STANDING) < shown.index(action.UNTIL)


def test_who_what_and_where_all_reshape_the_modal():
    built = action.blocks(412, {"type_key": "channel_ban"}, None)
    asks = {one.get("block_id"): one for one in built}
    assert asks[action.TARGET]["dispatch_action"]
    assert asks[action.KIND]["dispatch_action"]
    assert asks[action.WHERE]["dispatch_action"]


def test_a_submit_that_never_saw_the_warning_is_sent_back():
    said = {"type_key": "shush", "target_user_id": WHO, "expires_on": "2026-03-10"}
    shown = {action.TARGET, action.KIND, action.UNTIL, action.REASON}
    assert action.unasked(said, shown, standing(guard()))
    assert action.unasked(said, shown | {action.SETTLE}, standing(guard()))
    assert not action.unasked(
        said, shown | {action.STANDING, action.SETTLE}, standing(guard())
    )


def test_an_enforceable_kind_with_nothing_standing_is_not_asked():
    said = {"type_key": "shush", "target_user_id": WHO, "expires_on": "2026-03-10"}
    shown = {action.TARGET, action.KIND, action.UNTIL, action.REASON}
    assert not action.unasked(said, shown, standing(None))


def test_a_record_only_kind_goes_straight_through():
    said = {"type_key": "warning", "target_user_id": WHO}
    shown = {action.TARGET, action.KIND, action.REASON}
    assert not action.unasked(said, shown, standing(None, enforceable=False))
    assert not action.unasked(said, shown)


def test_settle_leaves_a_record_only_kind_alone():
    conn = Conn()
    found = memberguards.settle(conn, "warning", WHO, 412)
    assert found == {"enforceable": False, "found": None,
                     "reads": memberguards.UNGUARDED, "case_id": 412}
    assert conn.asked == []


def test_settle_waits_until_somebody_is_named():
    conn = Conn()
    found = memberguards.settle(conn, "shush", None, 412)
    assert found["enforceable"]
    assert found["found"] is None
    assert conn.asked == []


def test_settle_reads_what_it_finds_against_the_case_in_hand():
    row = tuple(guard(case_id=318)[field] for field in memberguards.FIELDS)
    found = memberguards.settle(Conn([row]), "shush", WHO, 412)
    assert found["reads"] == memberguards.ELSEWHERE
    assert found["found"]["case_id"] == 318
