import datetime as dt

from bot.nemo import record

ENDS = dt.datetime(2026, 3, 10, 12, tzinfo=dt.UTC)


def found(**over):
    row = {"kind": "shush", "expires_at": ENDS, "channel_id": None,
           "case_id": 412, "enforcement_status": "held", "enforced_by": "nemo"}
    row.update(over)
    return row


def test_nothing_held_says_so():
    assert record.standing_line(None) == "nothing standing"


def test_a_held_shush_reads_as_the_thing_it_is():
    assert record.standing_line(found()) == "shush until 10 Mar"


def test_a_channel_ban_names_its_channel():
    line = record.standing_line(found(kind="channel_ban", channel_id="C1"))
    assert line == "channel ban in <#C1> until 10 Mar"


def test_one_with_no_end_date_says_that_instead():
    assert record.standing_line(found(expires_at=None)) == "shush, no end date"


def test_one_nemo_has_not_carried_admits_it():
    assert record.standing_line(found(enforcement_status="pending")).endswith(
        "nemo has not carried it yet")


def test_one_nemo_has_dropped_admits_it():
    assert record.standing_line(found(enforcement_status="failed")).endswith("nemo is not holding it")


def test_one_done_by_hand_is_not_blamed_on_nemo():
    line = record.standing_line(found(enforced_by="by_hand", enforcement_status="held"))
    assert line.endswith("done by hand")
    assert "nemo" not in line


def test_standing_is_read_from_the_guards_not_the_actions():
    assert "fd.member_guards" in record.IN_FORCE
    assert "fd.actions" not in record.IN_FORCE
    assert "state IN ('live', 'lifting')" in record.IN_FORCE


def test_the_live_count_is_what_is_being_held():
    assert "FROM fd.member_guards" in record.COUNTS
    assert "state IN ('live', 'lifting')) AS live" in record.COUNTS


def test_the_counts_line_calls_it_what_it_is():
    line = record.counted({"subject_of": 1, "logged_in": 2, "live": 1, "reversed": 0})
    assert "1 in force" in line
    assert "action" not in line
