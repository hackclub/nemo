from bot.core import richtext


def section(*elements):
    return {"type": "rich_text", "elements": [
        {"type": "rich_text_section", "elements": list(elements)},
    ]}


def test_quote_blocks_single_section_returns_quote_with_same_elements():
    quote = richtext.quote_blocks([section(
        {"type": "text", "text": "hi "},
        {"type": "user", "user_id": "U1"},
    )])

    assert quote == {
        "type": "rich_text",
        "elements": [{"type": "rich_text_quote", "elements": [
            {"type": "text", "text": "hi "},
            {"type": "user", "user_id": "U1"},
        ]}],
    }


def test_quote_blocks_multiple_sections_merge_into_one_quote():
    quote = richtext.quote_blocks([section({"type": "text", "text": "a"}),
                                   section({"type": "text", "text": "b"})])

    assert quote["elements"][0]["elements"] == [
        {"type": "text", "text": "a"}, {"type": "text", "text": "b"}
    ]


def test_quote_blocks_preformatted_runs_get_code_style():
    quote = richtext.quote_blocks([{"type": "rich_text", "elements": [
        {"type": "rich_text_preformatted", "elements": [{"type": "text", "text": "code"}]},
    ]}])

    assert quote["elements"][0]["elements"] == [{"type": "text", "text": "code", "style": {"code": True}}]


def test_quote_blocks_section_quote_and_list_join_with_newlines():
    quote = richtext.quote_blocks([{"type": "rich_text", "elements": [
        {"type": "rich_text_quote", "elements": [{"type": "text", "text": "earlier"}]},
        {"type": "rich_text_list", "style": "ordered", "indent": 1, "elements": [
            {"type": "rich_text_section", "elements": [{"type": "text", "text": "first"}]},
            {"type": "rich_text_section", "elements": [{"type": "text", "text": "second"}]},
        ]},
        {"type": "rich_text_section", "elements": [{"type": "text", "text": "follow-up"}]},
    ]}])

    assert [run["text"] for run in quote["elements"][0]["elements"]] == [
        "earlier", "\n", "    1. ", "first", "\n", "    2. ", "second", "\n", "follow-up",
    ]


def test_quote_blocks_unknown_part_returns_none():
    quote = richtext.quote_blocks([{"type": "rich_text", "elements": [
        {"type": "rich_text_unknown", "elements": [{"type": "text", "text": "x"}]},
    ]}])

    assert quote is None


def test_elements_decode_slack_entities_in_text_runs():
    assert richtext.elements("&gt; a &lt;b&gt; &amp; c") == [{"type": "text", "text": "> a <b> & c"}]


def test_quote_blocks_non_rich_text_block_returns_none():
    quote = richtext.quote_blocks([{"type": "divider"}])

    assert quote is None


def test_quote_blocks_empty_input_returns_none():
    assert richtext.quote_blocks(None) is None
    assert richtext.quote_blocks([]) is None
    assert richtext.quote_blocks([section()]) is None
