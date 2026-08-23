from bot.nemo.cards import report as card


def blocks_of(kind, blocks):
    return [b for b in blocks if b["type"] == kind]


def text_of(blocks):
    out = []
    for block in blocks:
        if block["type"] == "header":
            out.append(block["text"]["text"])
        elif block["type"] == "section":
            if "text" in block:
                out.append(block["text"]["text"])
            for field in block.get("fields", []):
                out.append(field["text"])
        elif block["type"] == "rich_text":
            for element in block["elements"]:
                out.extend(part["text"] for part in element["elements"])
        elif block["type"] == "actions":
            out.extend(e["text"]["text"] for e in block["elements"])
        elif block["type"] == "divider":
            continue
        else:
            out.extend(e["text"] for e in block["elements"])
    return "\n".join(out)


def quoted(blocks):
    return "\n".join(
        part["text"]
        for block in blocks_of("rich_text", blocks)
        for element in block["elements"]
        for part in element["elements"]
    )


def a_case(**over):
    base = {"case_id": 2545, "body": "someone is being awful", "is_anonymous": True}
    base.update(over)
    return base


def test_the_header_says_what_it_is_and_where():
    blocks = card.blocks(
        a_case(
            category_key="bullying",
            shares=[{"kind": "forward", "source_channel_name": "lounge", "permalink": "https://x"}],
        )
    )
    assert blocks[0]["type"] == "header"
    assert blocks[0]["text"]["text"] == "Bullying in #lounge"


def test_the_case_number_is_still_on_the_card():
    assert "case *2545*" in text_of(card.blocks(a_case()))


def test_a_category_with_no_channel_says_only_what_it_is():
    assert card.blocks(a_case(category_key="spam"))[0]["text"]["text"] == "Spam"


def test_a_channel_with_no_category_says_only_where():
    blocks = card.blocks(
        a_case(shares=[{"kind": "forward", "source_channel_name": "lounge", "permalink": "https://x"}])
    )
    assert blocks[0]["text"]["text"] == "A report about #lounge"


def test_the_case_links_out_to_fire_engine():
    blocks = card.blocks(a_case(url="https://nemo.hackclub.com/fd/cases/2545"))
    assert "<https://nemo.hackclub.com/fd/cases/2545|open in Fire Engine>" in text_of(blocks)


def test_a_case_with_no_category_just_says_the_number():
    assert card.blocks(a_case())[0]["text"]["text"] == "Case 2545"


def test_the_category_reads_as_words_not_as_a_slug():
    blocks = card.blocks(a_case(category_key="harassment_general"))
    assert blocks[0]["text"]["text"] == "Systematic harassment, general"


def test_a_category_the_table_does_not_know_still_reads():
    assert card.blocks(a_case(category_key="brand_new"))[0]["text"]["text"] == "brand new"


def test_the_header_stays_within_slacks_limit():
    blocks = card.blocks(a_case(category_key="c" * 400))
    assert len(blocks[0]["text"]["text"]) <= card.HEADER_LIMIT


def test_the_report_is_quoted():
    assert quoted(card.blocks(a_case())) == "someone is being awful"


def test_a_report_with_no_words_still_reads():
    assert "only what is attached" in quoted(card.blocks(a_case(body="")))


def test_a_very_long_report_is_cut_and_says_so():
    body = quoted(card.blocks(a_case(body="x" * 5000)))
    assert len(body) <= card.QUOTE_LIMIT + len(card.CUT)
    assert "truncated" in body


def test_mentions_cannot_ping_the_firehouse():
    blocks = card.blocks(a_case(body="it was <@U0BAD> in <#C123>"))
    said = quoted(blocks)
    assert "<@U0BAD>" in said, "a quote block carries text literally"
    assert blocks_of("rich_text", card.blocks(a_case(body="<!channel>")))


def test_a_relayed_message_is_escaped_because_it_is_markdown():
    assert "&lt;@U0BAD&gt;" in card.to_member("it was <@U0BAD>")


def test_ampersands_survive_escaping_where_it_matters():
    assert "&amp;" in card.to_member("rock & roll")


def test_an_anonymous_report_never_names_the_reporter():
    body = text_of(card.blocks(a_case(reporter_user_id="UREPORTER")))
    assert "anonymous" in body
    assert "UREPORTER" not in body


def test_a_named_reporter_is_named():
    body = text_of(card.blocks(a_case(is_anonymous=False, reporter_user_id="UREPORTER")))
    assert "<@UREPORTER>" in body


def test_a_named_report_with_no_reporter_falls_back_to_anonymous():
    body = text_of(card.blocks(a_case(is_anonymous=False)))
    assert "anonymous" in body


def test_files_are_listed_by_name():
    blocks = card.blocks(a_case(files=[{"name": "shot.png", "fetch_state": "pending"}]))
    assert "shot.png" in text_of(blocks)


def test_an_external_file_says_where_it_lives():
    blocks = card.blocks(
        a_case(
            files=[
                {
                    "name": "notes",
                    "fetch_state": "skipped",
                    "external_url": "https://drive.google.com/x",
                }
            ]
        )
    )
    assert "lives outside Slack" in text_of(blocks)


def test_a_file_slack_lost_says_so():
    blocks = card.blocks(a_case(files=[{"name": "old.png", "fetch_state": "gone"}]))
    assert "Slack no longer has it" in text_of(blocks)


def test_a_file_with_no_name_falls_back_to_its_id():
    blocks = card.blocks(a_case(files=[{"slack_file_id": "F9", "fetch_state": "pending"}]))
    assert "F9" in text_of(blocks)


def test_forwarded_evidence_is_linked():
    blocks = card.blocks(
        a_case(
            shares=[
                {
                    "kind": "forward",
                    "source_channel_name": "lounge",
                    "permalink": "https://x/p/1",
                }
            ]
        )
    )
    assert "<https://x/p/1|#lounge>" in text_of(blocks)


def test_evidence_with_no_channel_name_still_shows():
    blocks = card.blocks(a_case(shares=[{"kind": "link", "permalink": "https://x/p/1"}]))
    assert "a linked message" in text_of(blocks)


def test_a_card_with_nothing_attached_carries_no_divider():
    kinds = [block["type"] for block in card.blocks(a_case())]
    assert kinds == ["header", "context", "rich_text", "section", "actions"]


def test_something_attached_earns_the_divider():
    kinds = [block["type"] for block in card.blocks(a_case(files=[{"name": "a.png"}]))]
    assert kinds == ["header", "context", "rich_text", "section", "divider", "context", "actions"]


def test_an_open_case_offers_to_be_claimed():
    acting = [b for b in card.blocks(a_case()) if b["type"] == "actions"][0]
    assert [e["action_id"] for e in acting["elements"]] == [card.CLAIM]
    assert acting["elements"][0]["value"] == "2545"


def test_a_held_case_offers_nothing_and_sends_you_to_fire_engine():
    blocks = card.blocks(a_case(assignees=["UQUINN"]))
    assert not [b for b in blocks if b["type"] == "actions"]


def test_a_resolved_case_offers_nothing():
    assert not [b for b in card.blocks(a_case(resolved_at="x")) if b["type"] == "actions"]


def test_context_blocks_stay_within_ten_elements():
    files = [{"name": f"f{n}.png", "fetch_state": "pending"} for n in range(30)]
    for block in blocks_of("context", card.blocks(a_case(files=files))):
        assert len(block["elements"]) <= 10


def test_every_section_stays_within_three_thousand_chars():
    shares = [
        {"kind": "forward", "source_channel_name": "c" * 200, "permalink": "https://x/" + "y" * 200}
        for _ in range(40)
    ]
    blocks = card.blocks(a_case(body="x" * 9000, shares=shares))
    for block in blocks_of("section", blocks):
        if "text" in block:
            assert len(block["text"]["text"]) <= 3000


def test_a_case_nobody_holds_reads_as_open():
    assert "*Open*" in text_of(card.blocks(a_case()))


def test_a_held_case_names_who_has_it():
    assert "<@UQUINN> has it" in text_of(card.blocks(a_case(assignees=["UQUINN"])))


def test_a_resolved_case_reads_as_resolved():
    body = text_of(card.blocks(a_case(resolved_at="2026-08-21")))
    assert "*Resolved*" in body
    assert "*Open*" not in body


def test_a_case_about_nobody_says_so_where_the_name_would_be():
    body = text_of(card.blocks(a_case()))
    assert "*About*\nnobody named yet" in body
    assert "Their record" not in body


def test_a_named_subject_brings_their_record():
    body = text_of(card.blocks(a_case(subjects=["UMILO"], other_cases=2)))
    assert "*About*\n<@UMILO>" in body
    assert "*Their record*\n2 other cases" in body
    assert ":warning: *2 other cases*" in body, "and it is flagged up top"


def test_a_subject_with_a_clean_record_says_so():
    assert "nothing else on their record" in text_of(
        card.blocks(a_case(subjects=["UMILO"], other_cases=0))
    )


def test_what_they_sent_is_named_not_counted():
    body = text_of(
        card.blocks(
            a_case(
                files=[{"name": "a.png", "fetch_state": "stored"}],
                shares=[{"kind": "link", "permalink": "https://x/p/1"}],
            )
        )
    )
    assert "a.png" in body
    assert "<https://x/p/1|a linked message>" in body


def test_who_is_holding_it_is_a_field_of_its_own():
    assert "*Held by*\nnobody yet" in text_of(card.blocks(a_case()))
    assert "*Held by*\n<@UQUINN>" in text_of(card.blocks(a_case(assignees=["UQUINN"])))
    assert "*Held by*\nclosed" in text_of(card.blocks(a_case(resolved_at="2026-08-21")))


def test_the_fallback_names_the_case():
    assert "2545" in card.fallback(a_case())
    assert "spam" in card.fallback(a_case(category_key="spam"))


def test_the_card_carries_the_case_in_its_metadata():
    carried = card.metadata(a_case(report_id=91))
    assert carried["event_type"] == "fd_case_card"
    assert carried["event_payload"] == {"case_id": 2545, "report_id": 91}
