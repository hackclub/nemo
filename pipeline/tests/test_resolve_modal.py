from datetime import datetime

from bot.nemo.cards import resolve


ENDS = datetime(2026, 8, 31, 23, 59)


def shush(user_id, expires_at=ENDS):
    return {"target_user_id": user_id, "type_key": "shush", "expires_at": expires_at}


def banned(user_id, expires_at=ENDS):
    return {"target_user_id": user_id, "type_key": "temp_ban", "expires_at": expires_at}


def channel_banned(user_id, channel_id="C0LOUNGE", expires_at=ENDS):
    return {
        "target_user_id": user_id,
        "type_key": "channel_ban",
        "expires_at": expires_at,
        "details": {"channel_id": channel_id},
    }


def rich(text):
    if text is None:
        return None
    return {
        "type": "rich_text",
        "elements": [
            {"type": "rich_text_section", "elements": [{"type": "text", "text": text}]}
        ],
    }


def state(why="not_conduct", note=None, telling=True, said=None):
    return {
        "values": {
            resolve.WHY: {
                resolve.WHY: {"selected_option": {"value": why} if why else None}
            },
            resolve.NOTE: {resolve.NOTE: {"rich_text_value": rich(note)}},
            resolve.TELL: {
                resolve.TELL: {
                    "selected_options": (
                        [{"value": resolve.TELLING}] if telling else []
                    )
                }
            },
            resolve.SAID: {resolve.SAID: {"value": said}},
        }
    }


def blocks_of(view, block_id):
    return next((b for b in view["blocks"] if b.get("block_id") == block_id), None)


def test_only_the_two_close_reasons_are_offered():
    assert resolve.reasons() == ["not_conduct", "no_action"]


def test_a_case_with_live_actions_lists_them_instead_of_asking_why():
    view = resolve.view(3864, live_actions=[shush("UQUINN"), banned("UMILO")])

    assert blocks_of(view, resolve.WHY) is None
    assert view["blocks"][0]["text"]["text"] == (
        "<@UQUINN> - shush until 31 Aug\n<@UMILO> - temporary ban until 31 Aug"
    )


def test_one_live_action_is_one_line():
    view = resolve.view(3864, live_actions=[shush("UQUINN")])
    assert view["blocks"][0]["text"]["text"] == "<@UQUINN> - shush until 31 Aug"


def test_an_action_that_never_ends_says_nothing_about_when():
    view = resolve.view(3864, live_actions=[{"target_user_id": "UQ", "type_key": "perma_ban"}])
    assert view["blocks"][0]["text"]["text"] == "<@UQ> - permanent ban"


def test_a_channel_ban_names_the_channel_it_covers():
    view = resolve.view(3864, live_actions=[channel_banned("UQUINN")])
    assert view["blocks"][0]["text"]["text"] == (
        "<@UQUINN> - channel ban in <#C0LOUNGE> until 31 Aug"
    )


def test_a_channel_ban_with_no_channel_on_the_row_still_reads():
    banned_nowhere = channel_banned("UQUINN")
    banned_nowhere["details"] = {}
    view = resolve.view(3864, live_actions=[banned_nowhere])
    assert view["blocks"][0]["text"]["text"] == "<@UQUINN> - channel ban until 31 Aug"


def test_a_case_with_no_action_has_to_be_told_why():
    view = resolve.view(3864)
    picker = blocks_of(view, resolve.WHY)
    assert [o["value"] for o in picker["element"]["options"]] == ["not_conduct", "no_action"]


def test_a_live_action_wins_over_whatever_was_picked():
    said = resolve.picked(state(why="no_action"), live_actions=1)
    assert said["resolution"] == "action_taken"


def test_nothing_picked_and_nothing_logged_is_refused():
    said = resolve.picked(state(why=None))
    assert resolve.objection(said) == {resolve.WHY: "Say why this case is closing."}


def test_the_reporter_is_told_by_default_but_only_when_there_is_one():
    with_reporter = resolve.view(3864, open_reports=1)
    assert blocks_of(with_reporter, resolve.TELL)["element"]["initial_options"]
    assert blocks_of(with_reporter, resolve.SAID)["element"]["initial_value"] == resolve.told()

    without = resolve.view(3864)
    assert blocks_of(without, resolve.TELL) is None
    assert blocks_of(without, resolve.SAID) is None


def test_unticking_the_box_means_nobody_is_told():
    assert resolve.picked(state(telling=False))["telling"] is False
    assert resolve.picked(state(telling=True))["telling"] is True


def test_an_empty_message_falls_back_to_the_standing_words():
    assert resolve.picked(state(said="   "))["said"] == resolve.told()
    assert resolve.picked(state(said="we spoke to them"))["said"] == "we spoke to them"


def test_the_note_is_kept_or_left_out_entirely():
    assert resolve.picked(state(note="  shushed for a week "))["member_note"] == (
        "shushed for a week"
    )
    assert resolve.picked(state(note="  "))["member_note"] is None
    assert resolve.picked(state(note=None))["member_note"] is None


def test_the_record_field_takes_mentions():
    picker = blocks_of(resolve.view(3864), resolve.NOTE)["element"]
    assert picker["type"] == "rich_text_input"


def test_a_mention_in_the_note_is_kept_as_the_id_the_dashboard_reads():
    said = {
        "values": {
            resolve.WHY: {resolve.WHY: {"selected_option": {"value": "no_action"}}},
            resolve.NOTE: {
                resolve.NOTE: {
                    "rich_text_value": {
                        "type": "rich_text",
                        "elements": [
                            {
                                "type": "rich_text_section",
                                "elements": [
                                    {"type": "text", "text": "spoke to "},
                                    {"type": "user", "user_id": "UQUINN"},
                                    {"type": "text", "text": " in "},
                                    {"type": "channel", "channel_id": "C0LOUNGE"},
                                ],
                            }
                        ],
                    }
                }
            },
            resolve.TELL: {resolve.TELL: {"selected_options": []}},
            resolve.SAID: {resolve.SAID: {"value": None}},
        }
    }
    assert resolve.picked(said)["member_note"] == "spoke to <@UQUINN> in <#C0LOUNGE>"


def test_a_mention_is_refused_in_what_the_reporter_is_told():
    wrong = resolve.objection(resolve.picked(state(said="ask <@UQUINN> about it")))
    assert list(wrong) == [resolve.SAID]

    fine = resolve.objection(resolve.picked(state(said="we spoke to them", telling=False)))
    assert fine is None


def test_what_it_says_afterwards_counts_who_was_told():
    said = resolve.picked(state())
    assert resolve.done(said, 3864, 0) == "*case 3864* closed as not a conduct matter"
    assert resolve.done(said, 3864, 1) == (
        "*case 3864* closed as not a conduct matter, 1 reporter told"
    )
    assert resolve.done(said, 3864, 2) == (
        "*case 3864* closed as not a conduct matter, 2 reporters told"
    )


def test_the_title_carries_the_case_so_the_body_does_not():
    view = resolve.view(3864)
    assert view["title"]["text"] == "Resolve · case 3864"
    assert view["submit"]["text"] == "Resolve"
    assert view["private_metadata"] == "3864"
    assert view["blocks"][0].get("block_id") == resolve.WHY, "the body opens with the question"


def test_the_title_stays_within_slacks_two_dozen_characters():
    for case_id in (9, 3864, 131685, 99999999):
        assert len(resolve.view(case_id)["title"]["text"]) <= resolve.TITLE_LIMIT
