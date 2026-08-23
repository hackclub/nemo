from bot.nemo.cards import action


def state(target="UQUINN", kind="warning", until=None, where=None):
    return {
        "values": {
            action.TARGET: {action.TARGET: {"selected_user": target}},
            action.KIND: {
                action.KIND: {"selected_option": {"value": kind} if kind else None}
            },
            action.UNTIL: {action.UNTIL: {"selected_date": until}},
            action.WHERE: {action.WHERE: {"selected_conversation": where}},
        }
    }


def test_the_modal_carries_the_case_and_nothing_else():
    view = action.view(3864)
    assert view["private_metadata"] == "3864"
    assert view["callback_id"] == action.CALLBACK
    assert view["submit"]["text"] == "Log it"


def test_the_subject_of_the_case_is_offered_first():
    view = action.view(3864, ["UQUINN"])
    picker = view["blocks"][1]["element"]
    assert picker["initial_user"] == "UQUINN"


def test_a_case_about_nobody_offers_nobody():
    picker = action.view(3864)["blocks"][1]["element"]
    assert "initial_user" not in picker


def test_every_action_the_dashboard_knows_is_offered():
    offered = [choice["value"] for choice in action.choices()]
    assert offered == list(action.table())
    assert "perma_ban" in offered


def test_what_was_picked_comes_back_flat():
    said = action.picked(state(kind="shush", until="2026-08-31"))
    assert said == {
        "target_user_id": "UQUINN",
        "type_key": "shush",
        "expires_on": "2026-08-31",
        "channel_id": None,
    }


def test_a_warning_needs_nothing_else():
    assert action.objection(action.picked(state())) is None


def test_a_shush_without_a_date_is_refused_on_the_date_field():
    wrong = action.objection(action.picked(state(kind="shush")))
    assert list(wrong) == [action.UNTIL]
    assert "shush needs a date" in wrong[action.UNTIL]


def test_a_channel_ban_needs_a_channel_and_a_date():
    wrong = action.objection(action.picked(state(kind="channel_ban")))
    assert list(wrong) == [action.UNTIL]

    wrong = action.objection(action.picked(state(kind="channel_ban", until="2026-09-01")))
    assert list(wrong) == [action.WHERE]


def test_nothing_picked_is_refused_on_the_kind():
    wrong = action.objection(action.picked(state(kind=None)))
    assert list(wrong) == [action.KIND]


def test_the_channel_is_kept_only_where_it_belongs():
    banned = action.picked(state(kind="channel_ban", until="2026-09-01", where="C1"))
    assert action.details(banned) == {"channel_id": "C1"}

    shushed = action.picked(state(kind="shush", until="2026-09-01", where="C1"))
    assert action.details(shushed) == {}


def test_a_permanent_ban_takes_no_date():
    assert action.objection(action.picked(state(kind="perma_ban"))) is None
    assert action.needs_expiry("perma_ban") is False


def test_the_word_it_reports_back_is_the_label():
    said = action.picked(state(kind="temp_ban", until="2026-09-01"))
    assert action.told(said, 3864) == "temporary ban logged on *case 3864*"


def test_the_case_is_named_once_in_the_body_not_in_the_title():
    view = action.view(3864)
    assert view["title"]["text"] == "Log an action"
    assert view["blocks"][0]["elements"][0]["text"] == "*case 3864*"
