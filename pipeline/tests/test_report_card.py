from bot.nemo.cards import report as card


def blocks_of(kind, blocks):
    return [b for b in blocks if b["type"] == kind]


def text_of(blocks):
    out = []
    for block in blocks:
        if block["type"] == "section":
            out.append(block["text"]["text"])
        else:
            out.extend(e["text"] for e in block["elements"])
    return "\n".join(out)


def a_case(**over):
    base = {"case_id": 2545, "body": "someone is being awful", "is_anonymous": True}
    base.update(over)
    return base


def test_the_case_number_leads():
    blocks = card.blocks(a_case())
    assert "*Case 2545*" in blocks[0]["text"]["text"]


def test_the_case_number_links_when_there_is_a_host():
    blocks = card.blocks(a_case(url="https://nemo.hackclub.com/fd/cases/2545"))
    assert "<https://nemo.hackclub.com/fd/cases/2545|Case 2545>" in blocks[0]["text"]["text"]


def test_a_case_with_no_category_says_so():
    assert "no category yet" in card.blocks(a_case())[0]["text"]["text"]


def test_the_category_shows_when_it_is_set():
    blocks = card.blocks(a_case(category_key="harassment_general"))
    assert "harassment_general" in blocks[0]["text"]["text"]


def test_the_report_is_quoted():
    assert "> someone is being awful" in text_of(card.blocks(a_case()))


def test_every_line_of_the_report_is_quoted():
    blocks = card.blocks(a_case(body="line one\nline two"))
    body = text_of(blocks)
    assert "> line one" in body
    assert "> line two" in body


def test_a_blank_line_stays_a_quote():
    blocks = card.blocks(a_case(body="one\n\ntwo"))
    assert "\n>\n" in text_of(blocks)


def test_a_report_with_no_words_still_reads():
    assert "only what is attached" in text_of(card.blocks(a_case(body="")))


def test_a_very_long_report_is_cut_and_says_so():
    blocks = card.blocks(a_case(body="x" * 5000))
    body = blocks[1]["text"]["text"]
    assert len(body) <= card.SECTION_LIMIT
    assert "truncated" in body


def test_mentions_cannot_ping_the_firehouse():
    blocks = card.blocks(a_case(body="it was <@U0BAD> in <#C123>"))
    body = text_of(blocks)
    assert "<@U0BAD>" not in body
    assert "&lt;@U0BAD&gt;" in body


def test_ampersands_survive_escaping():
    assert "&amp;" in text_of(card.blocks(a_case(body="rock & roll")))


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


def test_the_file_count_is_singular_for_one():
    blocks = card.blocks(a_case(files=[{"name": "a.png", "fetch_state": "pending"}]))
    assert "1 file" in text_of(blocks)
    assert "1 files" not in text_of(blocks)


def test_no_files_says_zero():
    assert "0 files" in text_of(card.blocks(a_case()))


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
    assert "a message" in text_of(blocks)


def test_no_evidence_means_no_evidence_block():
    assert "They pointed at" not in text_of(card.blocks(a_case()))


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
        assert len(block["text"]["text"]) <= 3000


def test_the_fallback_names_the_case():
    assert "2545" in card.fallback(a_case())
