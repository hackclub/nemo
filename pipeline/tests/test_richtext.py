from bot.engine import richtext
from bot.shroud import consent


def test_a_bare_mention_becomes_a_user_element():
    assert richtext.elements("<@U0A1>") == [{"type": "user", "user_id": "U0A1"}]


def test_a_labelled_mention_loses_the_stale_label():
    assert richtext.elements("<@U0A1|old-handle>") == [{"type": "user", "user_id": "U0A1"}]


def test_a_channel_link_becomes_a_channel_element():
    assert richtext.elements("in <#C0B2|lounge>") == [
        {"type": "text", "text": "in "},
        {"type": "channel", "channel_id": "C0B2"},
    ]


def test_a_workspace_user_id_counts_too():
    assert richtext.elements("<@W0C3>") == [{"type": "user", "user_id": "W0C3"}]


def test_several_mentions_keep_their_order_and_the_words_between():
    assert richtext.elements("<@U1> and <@U2> both") == [
        {"type": "user", "user_id": "U1"},
        {"type": "text", "text": " and "},
        {"type": "user", "user_id": "U2"},
        {"type": "text", "text": " both"},
    ]


def test_a_broadcast_is_left_as_words():
    assert richtext.elements("<!channel> now") == [
        {"type": "text", "text": "<!channel> now"}
    ]
    assert richtext.elements("<!here>") == [{"type": "text", "text": "<!here>"}]


def test_an_empty_body_is_still_one_element():
    assert richtext.elements("") == [{"type": "text", "text": ""}]
    assert richtext.elements(None) == [{"type": "text", "text": ""}]


def test_a_style_rides_along_on_the_words_only():
    said = richtext.elements("hi <@U1>", {"italic": True})
    assert said[0] == {"type": "text", "text": "hi ", "style": {"italic": True}}
    assert said[1] == {"type": "user", "user_id": "U1"}


def test_the_quote_wraps_the_elements_in_a_rich_text_quote():
    made = richtext.quote("<@U1> did it")
    assert made["type"] == "rich_text"
    assert made["elements"][0]["type"] == "rich_text_quote"
    assert made["elements"][0]["elements"][0] == {"type": "user", "user_id": "U1"}


def test_the_confirmation_shows_a_mention_as_a_mention():
    said = consent.quoted(["it was <@U0BAD> in <#C0LOUNGE>"])["elements"][0]["elements"]
    assert {"type": "user", "user_id": "U0BAD"} in said
    assert {"type": "channel", "channel_id": "C0LOUNGE"} in said


def test_the_confirmation_no_longer_escapes_what_it_shows():
    said = consent.quoted(["rock & roll <@U1>"])["elements"][0]["elements"]
    assert said[0] == {"type": "text", "text": "rock & roll "}


def test_a_report_with_only_files_says_so_in_italics():
    said = consent.quoted([""])["elements"][0]["elements"]
    assert said == [
        {
            "type": "text",
            "text": "no words yet, only what you attached",
            "style": {"italic": True},
        }
    ]


def test_a_long_report_is_still_cut_in_the_confirmation():
    said = consent.quoted(["x" * 5000])["elements"][0]["elements"]
    assert len(said[0]["text"]) <= consent.QUOTE_LIMIT + len(consent.CUT)
    assert "there is more" in said[0]["text"]


def test_the_prompt_counts_a_forward_as_well_as_a_file():
    said = consent.blocks(["look at this"], files=2, channels=["club-yarrow-help"])
    trail = [b for b in said if b["type"] == "context"][0]["elements"][0]["text"]

    assert "1 forwarded message, from #club-yarrow-help" in trail
    assert "2 files" in trail


def test_two_forwards_from_one_channel_name_it_once():
    assert consent.forwarded(["yarrow", "yarrow"]) == "2 forwarded messages, from #yarrow"


def test_a_forward_from_a_channel_with_no_name_still_counts():
    assert consent.forwarded([None]) == "1 forwarded message"


def test_a_report_with_nothing_attached_shows_no_trail():
    said = consent.blocks(["look at this"])
    assert not [b for b in said if b["type"] == "context"]


def test_a_pasted_link_becomes_a_link_element_not_literal_text():
    said = richtext.elements("<https://x.com/y>")
    assert said == [{"type": "link", "url": "https://x.com/y"}]


def test_slacks_escaped_ampersand_is_undone_in_the_href():
    url = ("https://hackclub.slack.com/archives/C09TTRZH94Z/p1787569865339089"
           "?thread_ts=1787568364.974219&amp;cid=C09TTRZH94Z")
    said = richtext.elements(f"<{url}|{url}>")

    assert said[0]["url"].count("&amp;") == 0
    assert "&cid=C09TTRZH94Z" in said[0]["url"]


def test_a_url_that_is_its_own_label_carries_no_second_copy():
    said = richtext.elements("<https://x.com/y|https://x.com/y>")
    assert "text" not in said[0]


def test_a_labelled_link_keeps_the_label():
    said = richtext.elements("<https://x.com/y|the thread>")
    assert said[0] == {"type": "link", "url": "https://x.com/y", "text": "the thread"}


def test_a_bare_url_is_linked_too():
    said = richtext.elements("read https://hackclub.com/conduct first")
    assert said[1] == {"type": "link", "url": "https://hackclub.com/conduct"}
    assert said[0]["text"] == "read "
    assert said[2]["text"] == " first"


def test_links_and_mentions_live_together():
    said = richtext.elements("<@U0BAD> sent <https://x.com/y|this> in <#C0LOUNGE>")
    assert [part["type"] for part in said] == [
        "user", "text", "link", "text", "channel"
    ]


def test_a_link_flattens_back_to_its_url():
    made = richtext.quote("see <https://x.com/y|this>")
    assert richtext.flatten(made) == "see https://x.com/y"


def test_a_link_is_not_a_mention_for_the_reporter_guard():
    assert richtext.mentions("<https://x.com/y>") is False
    assert richtext.mentions("<@U0BAD>") is True
