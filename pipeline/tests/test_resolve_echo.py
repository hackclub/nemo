from bot.nemo import case_actions
from bot.nemo.views import resolve

MOD = "UMOD"
WHO = "U1"


class Conn:
    def __init__(self, rows=()):
        self.rows = list(rows)
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchall(self):
        return self.rows


def action(**over):
    row = {"target_user_id": WHO, "type_key": "warning",
           "reason": "kept at it after being asked to stop", "resolution_note": None}
    row.update(over)
    return row


def test_resolution_echo_actions_reads_the_live_ones():
    conn = Conn([(WHO, "warning", "kept at it", None)])
    assert case_actions.resolution_echo_actions(conn, 412) == [
        {"target_user_id": WHO, "type_key": "warning", "reason": "kept at it",
         "resolution_note": None},
    ]
    assert conn.ran[0] == (case_actions.RESOLUTION_ECHO_ACTIONS, (412,))


def test_no_action_needed_names_the_disposition_in_the_byline():
    built = resolve.echo_blocks("no_action", None, MOD)
    assert built == [{
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": f"Resolved by <@{MOD}> · no action needed"}],
    }]


def test_a_summary_is_quoted_when_there_is_no_action():
    built = resolve.echo_blocks("not_conduct", "a misunderstanding, nothing more", MOD)
    assert built[1] == {"type": "divider"}
    assert built[2]["text"]["text"] == "> a misunderstanding, nothing more"


def test_action_taken_leaves_the_disposition_out_of_the_byline():
    built = resolve.echo_blocks("action_taken", None, MOD, [action()])
    assert built[0]["elements"][0]["text"] == f"Resolved by <@{MOD}>"


def test_action_taken_lists_every_action_with_its_reason():
    built = resolve.echo_blocks(
        "action_taken", None, MOD,
        [action(), action(type_key="channel_ban", target_user_id="U2", reason="repeated spam")],
    )
    assert built[1] == {"type": "divider"}
    assert built[2]["elements"][0]["text"] == f"*Warning* against <@{WHO}>"
    assert built[3]["text"]["text"] == "> kept at it after being asked to stop"
    assert built[4]["elements"][0]["text"] == "*Channel ban* against <@U2>"
    assert built[5]["text"]["text"] == "> repeated spam"


def test_action_taken_with_a_summary_calls_it_out_separately_from_the_reasons():
    built = resolve.echo_blocks("action_taken", "both stopped after the ban", MOD, [action()])
    footer = built[-1]["elements"][0]["text"]
    assert footer == "*How it was solved:* both stopped after the ban"
