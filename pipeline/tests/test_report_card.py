from bot.nemo.cards import edit
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
            for element in block["elements"]:
                if "text" in element:
                    out.append(element["text"]["text"])
                for choice in element.get("options", []):
                    out.append(choice["text"]["text"])
        elif block["type"] == "divider":
            continue
        else:
            out.extend(e["text"] for e in block["elements"])
    return "\n".join(out)


def quoted(blocks):
    said = []
    for block in blocks_of("rich_text", blocks):
        for element in block["elements"]:
            for part in element["elements"]:
                if part["type"] == "user":
                    said.append(f"@{part['user_id']}")
                elif part["type"] == "channel":
                    said.append(f"#{part['channel_id']}")
                else:
                    said.append(part["text"])
    return "".join(said)


def a_case(**over):
    base = {"case_id": 2545, "body": "someone is being awful", "is_anonymous": True}
    base.update(over)
    return base


def test_the_header_leads_with_the_number_then_what_it_is():
    blocks = card.blocks(
        a_case(
            category_key="bullying",
            shares=[{"kind": "forward", "source_channel_name": "lounge", "permalink": "https://x"}],
        )
    )
    assert blocks[0]["type"] == "header"
    assert blocks[0]["text"]["text"] == "Case 2545 · Bullying in #lounge"


def test_the_case_number_is_not_repeated_in_the_footer():
    footers = blocks_of("context", card.blocks(a_case()))
    assert "2545" not in "\n".join(e["text"] for f in footers for e in f["elements"])


def test_a_category_with_no_channel_says_only_what_it_is():
    assert card.blocks(a_case(category_key="spam"))[0]["text"]["text"] == "Case 2545 · Spam"


def test_a_channel_with_no_category_says_only_where():
    blocks = card.blocks(
        a_case(shares=[{"kind": "forward", "source_channel_name": "lounge", "permalink": "https://x"}])
    )
    assert blocks[0]["text"]["text"] == "Case 2545 · a report about #lounge"


def test_the_case_links_out_to_fire_engine():
    blocks = card.blocks(a_case(url="https://nemo.hackclub.com/fd/cases/2545"))
    assert "<https://nemo.hackclub.com/fd/cases/2545|open in fire engine>" in text_of(blocks)


def test_a_case_with_no_category_just_says_the_number():
    assert card.blocks(a_case())[0]["text"]["text"] == "Case 2545"


def test_the_category_reads_as_words_not_as_a_slug():
    blocks = card.blocks(a_case(category_key="harassment_general"))
    assert blocks[0]["text"]["text"] == "Case 2545 · Systematic harassment, general"


def test_a_category_the_table_does_not_know_still_reads():
    header = card.blocks(a_case(category_key="brand_new"))[0]["text"]["text"]
    assert header == "Case 2545 · brand new"


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


def parts_of(blocks):
    return [
        part
        for block in blocks_of("rich_text", blocks)
        for element in block["elements"]
        for part in element["elements"]
    ]


def test_a_mention_reads_as_a_name_not_as_an_id():
    said = parts_of(card.blocks(a_case(body="it was <@U0BAD> in <#C123>")))
    assert said[0] == {"type": "text", "text": "it was "}
    assert said[1] == {"type": "user", "user_id": "U0BAD"}
    assert said[2] == {"type": "text", "text": " in "}
    assert said[3] == {"type": "channel", "channel_id": "C123"}


def test_a_broadcast_stays_dead_text():
    said = parts_of(card.blocks(a_case(body="<!channel> look at this")))
    assert said == [{"type": "text", "text": "<!channel> look at this"}]


def test_a_report_with_no_mentions_is_still_one_run_of_text():
    assert parts_of(card.blocks(a_case())) == [
        {"type": "text", "text": "someone is being awful"}
    ]


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


def test_a_bare_card_is_four_blocks_and_everything_else_is_a_footer():
    kinds = [block["type"] for block in card.blocks(a_case())]
    assert kinds == ["header", "rich_text", "context", "actions"]


def test_what_is_attached_earns_a_second_footer_and_nothing_more():
    kinds = [block["type"] for block in card.blocks(a_case(files=[{"name": "a.png"}]))]
    assert kinds == ["header", "rich_text", "context", "context", "actions"]


def acting_on(case):
    return blocks_of("actions", card.blocks(case))[0]["elements"]


def test_an_open_case_offers_to_be_claimed():
    acting = acting_on(a_case())
    assert [e["action_id"] for e in acting] == [
        card.CLAIM,
        card.LOG_ACTION,
        card.RESOLVE,
        edit.MENU,
    ]
    assert acting[0]["value"] == "2545"


def test_a_held_case_keeps_its_buttons_but_not_the_claim():
    acting = acting_on(a_case(assignees=["UQUINN"]))
    assert [e["action_id"] for e in acting] == [card.LOG_ACTION, card.RESOLVE, edit.MENU]


def test_resolving_is_the_one_button_that_looks_dangerous():
    styles = {e["action_id"]: e.get("style") for e in acting_on(a_case())}
    assert styles == {
        card.CLAIM: "primary",
        card.LOG_ACTION: None,
        card.RESOLVE: "danger",
        edit.MENU: None,
    }


def test_the_overflow_offers_what_is_still_missing():
    bare = [o["text"]["text"] for o in acting_on(a_case())[-1]["options"]]
    assert bare == ["Say who it is about", "Set the violation", "Leave a note"]

    known = a_case(subjects=["UMILO"], category_key="spam", assignees=["UME"])
    assert [o["text"]["text"] for o in acting_on(known)[-1]["options"]] == [
        "Leave a note",
        "Hand it back",
    ]


def test_every_overflow_option_carries_the_case_it_belongs_to():
    for choice in acting_on(a_case())[-1]["options"]:
        assert edit.asked(choice["value"])[1] == 2545


def test_a_resolved_case_offers_only_the_way_back():
    acting = acting_on(a_case(resolved_at="2026-08-21"))
    assert [e["action_id"] for e in acting] == [card.REOPEN]
    assert "takes everybody off it" in acting[0]["confirm"]["text"]["text"]


def test_a_resolved_case_has_no_overflow_left():
    acting = acting_on(a_case(resolved_at="x"))
    assert not [e for e in acting if e["type"] == "overflow"]


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


def test_a_case_about_nobody_says_so_in_the_footer():
    assert "nobody named yet" in text_of(card.blocks(a_case()))


def test_a_named_subject_is_named_with_their_record_beside_them():
    body = text_of(card.blocks(a_case(subjects=["UMILO"], other_cases=2)))
    assert "about <@UMILO>" in body
    assert ":warning: *2 other cases*" in body


def test_a_subject_with_a_clean_record_is_not_flagged():
    body = text_of(card.blocks(a_case(subjects=["UMILO"], other_cases=0)))
    assert "about <@UMILO>" in body
    assert ":warning:" not in body, "a clean record earns no warning"


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


def test_the_footer_leads_with_where_the_case_stands():
    assert text_of(card.blocks(a_case())).count("*Open*") == 1
    assert "<@UQUINN> has it" in text_of(card.blocks(a_case(assignees=["UQUINN"])))
    assert "*Resolved*" in text_of(card.blocks(a_case(resolved_at="2026-08-21")))


def test_who_reported_it_and_when_sit_together():
    body = text_of(card.blocks(a_case(is_anonymous=False, reporter_user_id="UHAL")))
    assert "<@UHAL> reported it" in body
    assert "reported anonymously" in text_of(card.blocks(a_case()))


def test_the_fallback_names_the_case():
    assert "2545" in card.fallback(a_case())
    assert "spam" in card.fallback(a_case(category_key="spam"))


def test_the_card_carries_the_case_in_its_metadata():
    carried = card.metadata(a_case(report_id=91))
    assert carried["event_type"] == "fd_case_card"
    assert carried["event_payload"] == {"case_id": 2545, "report_id": 91}


def test_a_case_that_holds_threads_says_so_before_the_links():
    said = text_of(card.blocks(a_case(threads=1)))
    assert "*1 thread attached*" in said

    many = text_of(card.blocks(a_case(threads=3)))
    assert "*3 threads attached*" in many


def test_a_case_holding_nothing_says_nothing_about_threads():
    assert "attached" not in text_of(card.blocks(a_case()))
    assert "attached" not in text_of(card.blocks(a_case(threads=0)))


def test_the_thread_leads_the_footer_and_the_links_follow():
    blocks = card.blocks(
        a_case(threads=1, shares=[{"kind": "forward", "source_channel_name": "yarrow",
                                   "permalink": "https://x/p/1"}])
    )
    trail = blocks_of("context", blocks)[-1]["elements"][0]["text"]
    assert trail.startswith("*1 thread attached* · <https://x/p/1|#yarrow>")


def test_a_pasted_thread_link_survives_into_the_team_thread():
    link = "<https://hackclub.slack.com/archives/C0YARROW/p1755000000000900>"
    assert card.escape_but_slack(f"look at {link}") == f"look at {link}"


def test_a_labelled_link_survives_too():
    link = "<https://x/y|the thread>"
    assert card.escape_but_slack(link) == link


def test_the_team_thread_keeps_mentions_and_links_together():
    said = card.escape_but_slack("<@U0BAD> in <https://x/y> and <b>")
    assert "<@U0BAD>" in said
    assert "<https://x/y>" in said
    assert "&lt;b&gt;" in said


def test_a_reporter_gets_the_link_but_never_the_mention():
    said = card.to_member("read <https://x/y|the rules>, not <@U0BAD>")
    assert "<https://x/y|the rules>" in said
    assert "&lt;@U0BAD&gt;" in said, "a reporter must not be handed somebody else"


def test_a_link_nobody_shared_says_so():
    shares = [{"kind": "link", "source_channel_name": "club-yarrow-help",
               "permalink": "https://x/p/1", "is_reachable": False}]
    assert card.evidence(shares) == [
        "<https://x/p/1|#club-yarrow-help> (a link, not shared)"
    ]


def test_a_message_they_did_share_reads_plainly():
    shares = [{"kind": "forward", "source_channel_name": "club-yarrow-help",
               "permalink": "https://x/p/1", "is_reachable": True}]
    assert card.evidence(shares) == ["<https://x/p/1|#club-yarrow-help>"]


def a_share(**over):
    base = {"kind": "unfurl", "source_channel_id": "C0YARROW",
            "source_channel_name": "club-yarrow-help", "source_ts": "1787569865.339089",
            "permalink": "https://x/p/1", "is_reachable": True,
            "source_author_user_id": "UMILO",
            "source_body": "go back to your own server"}
    base.update(over)
    return base


def test_the_card_shows_what_was_reported_not_only_that_something_was():
    said = text_of(card.blocks(a_case(shares=[a_share()])))

    assert "go back to your own server" in said
    assert "<@UMILO> in #club-yarrow-help" in said


def test_the_reported_message_sits_under_the_report_and_above_the_footer():
    kinds = [b["type"] for b in card.blocks(a_case(shares=[a_share()]))]
    assert kinds[:5] == ["header", "rich_text", "context", "rich_text", "context"]


def test_a_link_nobody_shared_has_no_words_to_show():
    said = text_of(card.blocks(a_case(shares=[a_share(is_reachable=False, source_body=None)])))
    assert "go back to your own server" not in said


def test_an_author_slack_did_not_name_is_still_shown():
    said = text_of(card.blocks(a_case(shares=[a_share(source_author_user_id=None)])))
    assert "somebody in #club-yarrow-help" in said


def test_only_the_first_few_reported_messages_are_shown():
    many = [a_share(source_ts=str(n), source_body=f"line {n}") for n in range(6)]
    said = text_of(card.blocks(a_case(shares=many)))

    assert "line 0" in said
    assert "line 5" not in said
