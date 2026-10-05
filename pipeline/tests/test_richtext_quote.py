from bot.core import richtext


def section(*elements):
    return {"type": "rich_text", "elements": [
        {"type": "rich_text_section", "elements": list(elements)},
    ]}


def test_a_single_section_becomes_a_quote_with_the_same_runs():
    made = richtext.quote_blocks([section(
        {"type": "text", "text": "hi "},
        {"type": "user", "user_id": "U1"},
    )])

    assert made == {
        "type": "rich_text",
        "elements": [{"type": "rich_text_quote", "elements": [
            {"type": "text", "text": "hi "},
            {"type": "user", "user_id": "U1"},
        ]}],
    }


def test_several_sections_are_joined_into_one_quote():
    made = richtext.quote_blocks([section({"type": "text", "text": "a"}),
                                   section({"type": "text", "text": "b"})])

    assert made["elements"][0]["elements"] == [
        {"type": "text", "text": "a"}, {"type": "text", "text": "b"}
    ]


def test_a_non_section_element_refuses_the_whole_thing():
    made = richtext.quote_blocks([{"type": "rich_text", "elements": [
        {"type": "rich_text_preformatted", "elements": [{"type": "text", "text": "code"}]},
    ]}])

    assert made is None


def test_a_block_that_is_not_rich_text_refuses_the_whole_thing():
    made = richtext.quote_blocks([{"type": "divider"}])

    assert made is None


def test_nothing_in_makes_nothing_out():
    assert richtext.quote_blocks(None) is None
    assert richtext.quote_blocks([]) is None
    assert richtext.quote_blocks([section()]) is None
