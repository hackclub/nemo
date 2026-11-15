import datetime as dt

from bot.nemo import memberguards
from bot.nemo.views import action

CHANNEL_ID = "C1"
USER_ID = "U1"
MOD = "UMOD"
OPENED_AT = dt.datetime(2026, 3, 3, 12, tzinfo=dt.UTC)
EXPIRES_AT = dt.datetime(2026, 3, 10, 12, tzinfo=dt.UTC)


class Conn:
    def __init__(self, rows=()):
        self.rows = list(rows)
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        return self.rows[0] if self.rows else None


def guard(**over):
    row = {
        "id": 7, "kind": "shush", "subject_id": USER_ID, "channel_id": None,
        "state": "live", "enforcement_status": "held", "enforced_by": "nemo", "case_id": None,
        "opened_by": MOD, "opened_at": OPENED_AT, "reason": "being awful",
        "expires_at": EXPIRES_AT,
    }
    row.update(over)
    return row


def ids(built):
    return [one.get("block_id") for one in built]


def block_text(built):
    parts = []
    for one in built:
        if one.get("type") == "section":
            parts.append(one["text"]["text"])
        if one.get("type") == "context":
            parts += [item.get("text", "") for item in one["elements"]]
    return "\n".join(parts)


def status_for(guard_row, case_id=412, enforceable=True):
    return {"enforceable": enforceable, "guard": guard_row, "case_id": case_id,
            "relation": memberguards.guard_relation(guard_row, case_id)}


def test_build_blocks_with_no_guard_omits_guard_status():
    built = action.build_blocks(412, {"type_key": "shush", "target_user_id": USER_ID},
                          status_for(None))
    assert action.GUARD_STATUS not in ids(built)


def test_build_blocks_record_only_kind_omits_guard_status():
    built = action.build_blocks(412, {"type_key": "warning", "target_user_id": USER_ID}, None)
    assert action.GUARD_STATUS not in ids(built)


def submission(**over):
    row = {"type_key": "warning", "target_user_id": USER_ID,
           "reason": "kept at it after being asked to stop"}
    row.update(over)
    return row


def test_log_blocks_has_header_and_target_context():
    built = action.log_blocks(submission(), MOD)
    assert built[0] == {"type": "header", "text": {"type": "plain_text", "text": "Warning"}}
    assert built[1]["elements"][0]["text"] == f"Against <@{USER_ID}>, logged by <@{MOD}>"
    assert built[2] == {"type": "divider"}


def test_log_blocks_quotes_reason():
    built = action.log_blocks(submission(), MOD)
    quoted = next(one for one in built if one["type"] == "section")
    assert quoted["text"]["text"] == "> kept at it after being asked to stop"


def test_log_blocks_channel_ban_header_has_channel_name_and_byline_has_end_date():
    built = action.log_blocks(
        submission(type_key="channel_ban", channel_id="CGEN", expires_on="2026-03-10"), MOD,
        channel_name="general",
    )
    assert built[0]["text"]["text"] == "Channel ban from #general"
    assert built[1]["elements"][0]["text"] == f"Against <@{USER_ID}> until 10 Mar, logged by <@{MOD}>"


def test_log_blocks_channel_ban_without_name_uses_channel_id():
    built = action.log_blocks(
        submission(type_key="channel_ban", channel_id="CGEN", expires_on="2026-03-10"), MOD,
    )
    assert built[0]["text"]["text"] == "Channel ban from CGEN"


def test_log_blocks_shush_byline_has_end_date_without_channel():
    built = action.log_blocks(submission(type_key="shush", expires_on="2026-03-10"), MOD)
    assert built[0]["text"]["text"] == "Shush"
    assert built[1]["elements"][0]["text"] == f"Against <@{USER_ID}> until 10 Mar, logged by <@{MOD}>"


def test_log_blocks_temp_ban_end_time_is_a_date_token():
    built = action.log_blocks(
        submission(type_key="temp_ban", expires_on="2026-03-10", expires_time="20:00", timezone="Africa/Cairo"), MOD,
    )
    assert built[0]["text"]["text"] == "Temporary ban"
    assert built[1]["elements"][0]["text"] == (
        f"Against <@{USER_ID}> until <!date^1773165600^{{date_short_pretty}} at {{time}}|10 Mar 2026, 18:00 UTC>, "
        f"logged by <@{MOD}>"
    )


def test_log_blocks_perma_ban_header_has_no_end_date():
    built = action.log_blocks(submission(type_key="perma_ban"), MOD)
    assert built[0]["text"]["text"] == "Permanent ban"


def test_build_blocks_has_no_outcome_field():
    built = action.build_blocks(412, {"type_key": "shush", "target_user_id": USER_ID}, None)
    labels = [one.get("label", {}).get("text") for one in built]
    assert "Outcome" not in labels
    assert "resolution_note" not in action.submitted_values({"values": {}})


def test_build_blocks_guard_without_case_shows_no_case_warning():
    built = action.build_blocks(412, {"type_key": "shush"}, status_for(guard()))
    assert action.GUARD_STATUS in ids(built)
    text = block_text(built)
    assert f"<@{USER_ID}> already has an active shush with no case" in text
    assert f"set by <@{MOD}>" in text
    assert "since 3 Mar" in text
    assert "until 10 Mar" in text


def test_build_blocks_guard_on_other_case_shows_case_id():
    built = action.build_blocks(412, {"type_key": "shush"}, status_for(guard(case_id=318)))
    assert "on *case 318*" in block_text(built)


def test_build_blocks_guard_on_same_case_shows_this_case():
    built = action.build_blocks(412, {"type_key": "shush"}, status_for(guard(case_id=412)))
    assert "on this case" in block_text(built)


def test_build_blocks_channel_ban_guard_shows_channel():
    guard_row = guard(kind="channel_ban", channel_id=CHANNEL_ID)
    built = action.build_blocks(412, {"type_key": "channel_ban"}, status_for(guard_row))
    assert f"channel ban in <#{CHANNEL_ID}>" in block_text(built)


def test_build_blocks_guard_without_expiry_shows_no_end_date():
    built = action.build_blocks(412, {"type_key": "shush"}, status_for(guard(expires_at=None)))
    assert "no end date" in block_text(built)
    assert "until" not in block_text(built)


def test_build_blocks_pending_guard_shows_pending():
    built = action.build_blocks(412, {"type_key": "shush"}, status_for(guard(enforcement_status="pending")))
    assert "pending" in block_text(built)


def test_build_blocks_failed_guard_shows_not_enforced():
    built = action.build_blocks(412, {"type_key": "shush"}, status_for(guard(enforcement_status="failed")))
    assert "not enforced" in block_text(built)


def test_build_blocks_manual_guard_shows_manual():
    guard_row = guard(enforced_by="by_hand", enforcement_status="held")
    text = block_text(action.build_blocks(412, {"type_key": "shush"}, status_for(guard_row)))
    assert "manual" in text
    assert "not enforced" not in text


def test_build_blocks_guard_status_precedes_until():
    built = action.build_blocks(412, {"type_key": "shush"}, status_for(guard()))
    block_ids = ids(built)
    assert block_ids.index(action.GUARD_STATUS) < block_ids.index(action.UNTIL)


def test_build_blocks_target_kind_and_where_use_dispatch_action():
    built = action.build_blocks(412, {"type_key": "channel_ban"}, None)
    blocks_by_id = {one.get("block_id"): one for one in built}
    assert blocks_by_id[action.TARGET]["dispatch_action"]
    assert blocks_by_id[action.KIND]["dispatch_action"]
    assert blocks_by_id[action.WHERE]["dispatch_action"]


def test_requires_refresh_when_guard_status_block_missing():
    values = {"type_key": "shush", "target_user_id": USER_ID, "expires_on": "2026-03-10"}
    visible_blocks = {action.TARGET, action.KIND, action.UNTIL, action.REASON}
    assert action.requires_refresh(values, visible_blocks, status_for(guard()))
    assert action.requires_refresh(values, visible_blocks | {action.ENFORCEMENT}, status_for(guard()))
    assert not action.requires_refresh(
        values, visible_blocks | {action.GUARD_STATUS, action.ENFORCEMENT}, status_for(guard())
    )


def test_requires_refresh_enforceable_kind_without_guard_is_false():
    values = {"type_key": "shush", "target_user_id": USER_ID, "expires_on": "2026-03-10"}
    visible_blocks = {action.TARGET, action.KIND, action.UNTIL, action.REASON}
    assert not action.requires_refresh(values, visible_blocks, status_for(None))


def test_requires_refresh_record_only_kind_is_false():
    values = {"type_key": "warning", "target_user_id": USER_ID}
    visible_blocks = {action.TARGET, action.KIND, action.REASON}
    assert not action.requires_refresh(values, visible_blocks, status_for(None, enforceable=False))
    assert not action.requires_refresh(values, visible_blocks)


def test_guard_status_record_only_kind_skips_query():
    conn = Conn()
    result = memberguards.guard_status(conn, "warning", USER_ID, 412)
    assert result == {"enforceable": False, "guard": None,
                      "relation": memberguards.NO_GUARD, "case_id": 412}
    assert conn.executed == []


def test_guard_status_without_subject_skips_query():
    conn = Conn()
    result = memberguards.guard_status(conn, "shush", None, 412)
    assert result["enforceable"]
    assert result["guard"] is None
    assert conn.executed == []


def test_guard_status_guard_on_other_case_returns_other_case_relation():
    row = tuple(guard(case_id=318)[field] for field in memberguards.FIELDS)
    result = memberguards.guard_status(Conn([row]), "shush", USER_ID, 412)
    assert result["relation"] == memberguards.OTHER_CASE
    assert result["guard"]["case_id"] == 318
