from bot.nemo.cards import edit


def rich(text):
    return {
        "type": "rich_text",
        "elements": [
            {"type": "rich_text_section", "elements": [{"type": "text", "text": text}]}
        ],
    }


def test_a_verb_and_a_case_travel_together_in_one_value():
    assert edit.asked(f"{edit.NOTE}:3864") == (edit.NOTE, 3864)
    assert edit.asked(f"{edit.HAND_BACK}:12") == (edit.HAND_BACK, 12)


def test_a_value_that_makes_no_sense_names_no_case():
    assert edit.asked("nonsense")[1] is None
    assert edit.asked("")[1] is None
    assert edit.asked(None)[1] is None


def test_the_menu_disappears_when_there_is_nothing_left_to_ask():
    settled = {"case_id": 1, "subjects": ["UQ"], "category_key": "spam"}
    assert [o["text"]["text"] for o in edit.menu(settled, mine=False)["options"]] == [
        "Leave a note"
    ]


def test_the_menu_stays_within_slacks_five_options():
    bare = {"case_id": 1}
    assert len(edit.menu(bare, mine=True)["options"]) <= 5


def test_who_it_is_about_asks_for_one_person_and_nothing_else():
    view = edit.subject_view(3864)
    assert view["callback_id"] == edit.SUBJECT
    assert view["private_metadata"] == "3864"
    assert view["title"]["text"] == "Subject · case 3864"
    assert len(view["blocks"]) == 1
    assert view["blocks"][0]["element"]["type"] == "users_select"


def test_the_violation_offers_all_seventeen_in_words():
    view = edit.category_view(3864)
    assert view["title"]["text"] == "Violation · case 3864"
    options = view["blocks"][0]["element"]["options"]
    assert len(options) == 17
    assert options[0]["text"]["text"] == "Misconduct not otherwise specified"
    assert options[0]["value"] == "nos"


def test_the_violation_modal_is_the_picker_and_nothing_else():
    block = edit.category_view(3864)["blocks"][0]
    assert "hint" not in block
    assert block["element"]["type"] == "static_select"


def test_the_case_is_named_in_the_title_and_never_in_the_body():
    for view in (edit.subject_view(8), edit.category_view(8), edit.note_view(8)):
        assert view["title"]["text"].endswith("· case 8")
        assert not [b for b in view["blocks"] if b["type"] == "context"]


def test_no_field_carries_a_label_the_title_already_gave():
    for view in (edit.subject_view(8), edit.category_view(8), edit.note_view(8)):
        for block in view["blocks"]:
            assert block["label"]["text"] == edit.NO_LABEL


def test_the_note_takes_mentions_and_keeps_them_as_ids():
    view = edit.note_view(3864)
    assert view["blocks"][0]["element"]["type"] == "rich_text_input"

    said = {
        "values": {
            edit.SAID: {
                edit.SAID: {
                    "rich_text_value": {
                        "type": "rich_text",
                        "elements": [
                            {
                                "type": "rich_text_section",
                                "elements": [
                                    {"type": "text", "text": "spoke to "},
                                    {"type": "user", "user_id": "UQUINN"},
                                ],
                            }
                        ],
                    }
                }
            }
        }
    }
    assert edit.said_picked(said) == "spoke to <@UQUINN>"


def test_an_empty_note_is_refused_on_the_field():
    said = {"values": {edit.SAID: {edit.SAID: {"rich_text_value": rich("   ")}}}}
    picked = edit.said_picked(said)
    assert edit.note_objection(picked) == {edit.SAID: "Write something first."}


def test_a_very_long_note_is_cut_to_what_the_column_takes():
    said = {"values": {edit.SAID: {edit.SAID: {"rich_text_value": rich("x" * 9000)}}}}
    assert len(edit.said_picked(said)) == edit.NOTE_LIMIT


def test_every_title_stays_within_slacks_two_dozen_characters():
    for view in (edit.subject_view(131685), edit.category_view(131685), edit.note_view(131685)):
        assert len(view["title"]["text"]) <= edit.TITLE_LIMIT
