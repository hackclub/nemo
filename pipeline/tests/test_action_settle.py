import datetime as dt

from bot.nemo import memberguards
from bot.nemo.views import action

WHO = "U1"
MOD = "UMOD"
ROOM = "C1"
ENDS = dt.datetime(2026, 3, 10, 12, tzinfo=dt.UTC)


class Conn:
    def __init__(self, rows=None):
        self.rows = rows if rows is not None else {}
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        for mark, row in self.rows.items():
            if mark in self.ran[-1][0]:
                return row
        return None

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


def guard(**over):
    row = {
        "id": 7, "kind": "shush", "subject_id": WHO, "channel_id": None,
        "state": "live", "enforcement_status": "held", "enforced_by": "nemo", "case_id": None,
        "opened_by": MOD, "opened_at": None, "reason": "being awful", "expires_at": ENDS,
    }
    row.update(over)
    return row


def standing(found, reads, case_id=412, enforceable=True):
    return {"enforceable": enforceable, "found": found, "reads": reads, "case_id": case_id}


def submission(**over):
    row = {"type_key": "shush", "target_user_id": WHO, "reason": "being awful",
           "expires_on": "2026-03-10"}
    row.update(over)
    return row


def options(said_, standing_):
    return [value for value, _text in action.settle_options(said_, standing_)]


def test_a_record_only_kind_is_never_asked():
    assert options(submission(type_key="warning"), standing(None, action.UNGUARDED,
                                                      enforceable=False)) == []


def test_nothing_standing_is_not_asked_it_is_simply_taken():
    assert options(submission(), standing(None, action.UNGUARDED)) == []


def test_an_orphan_is_offered_for_adoption_first():
    assert options(submission(), standing(guard(), action.ORPHANED)) == [action.ADOPT, action.RECORD]


def test_a_guard_under_another_case_defaults_to_leaving_it_alone():
    built = action.settle_blocks(submission(), standing(guard(case_id=318), action.ELSEWHERE))
    submitted_values = built[0]["element"]["initial_option"]["value"]
    assert submitted_values == action.RECORD
    assert options(submission(), standing(guard(case_id=318), action.ELSEWHERE)) == [
        action.EXTEND, action.RECORD]


def test_an_orphan_defaults_to_being_adopted():
    built = action.settle_blocks(submission(), standing(guard(), action.ORPHANED))
    assert built[0]["element"]["initial_option"]["value"] == action.ADOPT


def test_a_kind_that_never_expires_is_not_offered_an_extension():
    found = guard(kind="indef_ban", expires_at=None)
    assert options(submission(type_key="indef_ban"), standing(found, action.ELSEWHERE)) == []


def test_what_they_already_picked_survives_a_reshape():
    built = action.settle_blocks(submission(settle=action.RECORD),
                                 standing(guard(), action.ORPHANED))
    assert built[0]["element"]["initial_option"]["value"] == action.RECORD


def test_the_choice_sits_below_the_date_it_talks_about():
    built = action.build_blocks(412, submission(), standing(guard(case_id=318), action.ELSEWHERE))
    shown = [one.get("block_id") for one in built]
    assert shown.index(action.UNTIL) < shown.index(action.SETTLE)


def test_a_submit_with_nothing_standing_goes_straight_through():
    shown = {action.TARGET, action.KIND, action.UNTIL, action.REASON}
    assert not action.requires_refresh(submission(), shown, standing(None, action.UNGUARDED))


def test_a_submit_that_never_saw_an_orphan_is_sent_back():
    shown = {action.TARGET, action.KIND, action.UNTIL, action.REASON, action.STANDING}
    held = standing(guard(), action.ORPHANED)
    assert action.requires_refresh(submission(), shown, held)
    assert not action.requires_refresh(submission(), shown | {action.SETTLE}, held)


def test_resolution_note_is_never_required():
    assert action.validation_errors(submission()) is None
    assert action.validation_errors(submission(resolution_note="")) is None
    assert action.validation_errors(submission(resolution_note="talked it through")) is None


def test_extending_without_a_date_is_refused():
    wrong = action.validation_errors(submission(settle=action.EXTEND, expires_on=None))
    assert action.UNTIL in wrong


def test_carrying_it_opens_a_guard_nemo_has_not_done_yet():
    conn = Conn({"INSERT INTO fd.member_guards": (9,), "UPDATE fd.actions": (1,)})
    guard_id = memberguards.settled(conn, 1, submission(settle=action.CARRY),
                                    standing(None, action.UNGUARDED), MOD)
    assert guard_id == 9
    opened = conn.did("INSERT INTO fd.member_guards")[0]
    assert opened[0] == "shush"
    assert opened[3] == 412
    assert opened[7:9] == ("nemo", "pending")
    assert conn.did("UPDATE fd.actions")[0] == (9, 1)


def test_nothing_standing_always_opens_a_guard_nemo_will_carry():
    conn = Conn({"INSERT INTO fd.member_guards": (9,), "UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1, submission(), standing(None, action.UNGUARDED), MOD)
    assert conn.did("INSERT INTO fd.member_guards")[0][7:9] == ("nemo", "pending")


def test_a_workspace_guard_is_opened_without_a_channel():
    conn = Conn({"INSERT INTO fd.member_guards": (9,), "UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1, submission(settle=action.CARRY, channel_id=ROOM),
                         standing(None, action.UNGUARDED), MOD)
    assert conn.did("INSERT INTO fd.member_guards")[0][2] is None


def test_a_channel_guard_keeps_the_channel_it_was_given():
    conn = Conn({"INSERT INTO fd.member_guards": (9,), "UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1,
                         submission(type_key="channel_ban", settle=action.CARRY, channel_id=ROOM),
                         standing(None, action.UNGUARDED), MOD)
    assert conn.did("INSERT INTO fd.member_guards")[0][2] == ROOM


def test_adopting_an_orphan_puts_it_on_this_case_and_links_the_action():
    conn = Conn({"UPDATE fd.member_guards SET case_id": (7,), "UPDATE fd.actions": (1,)})
    guard_id = memberguards.settled(conn, 1, submission(settle=action.ADOPT),
                                    standing(guard(), action.ORPHANED), MOD)
    assert guard_id == 7
    assert conn.did("UPDATE fd.member_guards SET case_id")[0] == (412, 7)
    assert conn.did("UPDATE fd.actions")[0] == (7, 1)


def test_an_orphan_left_alone_is_neither_touched_nor_linked():
    conn = Conn({"UPDATE fd.actions": (1,)})
    guard_id = memberguards.settled(conn, 1, submission(settle=action.RECORD),
                                    standing(guard(), action.ORPHANED), MOD)
    assert guard_id is None
    assert conn.did("UPDATE fd.member_guards SET case_id") == []
    assert conn.did("UPDATE fd.actions") == []


def test_extending_moves_the_date_on_the_guard_that_already_exists():
    conn = Conn({"UPDATE fd.member_guards SET expires_at": (7,), "UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1, submission(settle=action.EXTEND, expires_on="2026-04-01"),
                         standing(guard(case_id=318), action.ELSEWHERE), MOD)
    assert conn.did("UPDATE fd.member_guards SET expires_at")[0] == ("2026-04-01 23:59:59", 7)


def test_a_guard_under_another_case_left_alone_is_not_claimed():
    conn = Conn({"UPDATE fd.actions": (1,)})
    guard_id = memberguards.settled(conn, 1, submission(settle=action.RECORD),
                                    standing(guard(case_id=318), action.ELSEWHERE), MOD)
    assert guard_id is None
    assert conn.did("UPDATE fd.actions") == []


def test_a_guard_already_on_this_case_is_linked_without_being_changed():
    conn = Conn({"UPDATE fd.actions": (1,)})
    guard_id = memberguards.settled(conn, 1, submission(settle=action.RECORD),
                                    standing(guard(case_id=412), action.HERE), MOD)
    assert guard_id == 7
    assert conn.did("UPDATE fd.member_guards SET case_id") == []
    assert conn.did("UPDATE fd.actions")[0] == (7, 1)


def test_a_record_only_kind_writes_no_guard_at_all():
    conn = Conn()
    assert memberguards.settled(conn, 1, submission(type_key="warning"),
                                standing(None, action.UNGUARDED, enforceable=False), MOD) is None
    assert conn.ran == []


def test_losing_the_race_to_another_guard_leaves_the_action_unlinked():
    conn = Conn({"UPDATE fd.actions": (1,)})
    guard_id = memberguards.settled(conn, 1, submission(settle=action.CARRY),
                                    standing(None, action.UNGUARDED), MOD)
    assert guard_id is None
    assert conn.did("UPDATE fd.actions") == []


def test_an_orphan_adopted_out_from_under_us_leaves_the_action_unlinked():
    conn = Conn({"UPDATE fd.actions": (1,)})
    guard_id = memberguards.settled(conn, 1, submission(settle=action.ADOPT),
                                    standing(guard(), action.ORPHANED), MOD)
    assert guard_id is None
    assert conn.did("UPDATE fd.actions") == []


def verbs(conn):
    return [args[4] for args in conn.did("INSERT INTO fd.audit")]


def test_opening_a_guard_is_written_down_against_the_guard():
    conn = Conn({"INSERT INTO fd.member_guards": (9,), "UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1, submission(settle=action.CARRY),
                         standing(None, action.UNGUARDED), MOD)
    told = conn.did("INSERT INTO fd.audit")[0]
    assert told[2:5] == ("member_guard", 9, "opened")


def test_adopting_and_extending_are_written_down_too():
    conn = Conn({"UPDATE fd.member_guards SET case_id": (7,), "UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1, submission(settle=action.ADOPT),
                         standing(guard(), action.ORPHANED), MOD)
    assert verbs(conn) == ["attached"]

    conn = Conn({"UPDATE fd.member_guards SET expires_at": (7,), "UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1, submission(settle=action.EXTEND),
                         standing(guard(case_id=318), action.ELSEWHERE), MOD)
    assert verbs(conn) == ["extended"]


def test_leaving_a_guard_alone_is_not_written_down_as_a_change():
    conn = Conn({"UPDATE fd.actions": (1,)})
    memberguards.settled(conn, 1, submission(settle=action.RECORD),
                         standing(guard(case_id=412), action.HERE), MOD)
    assert verbs(conn) == []


def test_every_verb_the_writes_use_is_declared_on_the_capability():
    import yaml
    from lib.paths import CAPABILITIES_FILE

    held = yaml.safe_load(CAPABILITIES_FILE.read_text())
    told = set(held["capabilities"]["case.act"]["events"])
    assert {"member_guard/opened", "member_guard/attached",
            "member_guard/extended"} <= told
