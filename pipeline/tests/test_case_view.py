import datetime as dt

from bot.core.formatting import short_end
from bot.nemo.views import case_card, case_view

AT = dt.datetime(2026, 10, 17, 12, 0, tzinfo=dt.UTC)
NAMED = {"anonymous": False, "user_id": "UREPORTER", "icon": "https://img/reporter.png"}
ANONYMOUS = {"anonymous": True, "user_id": None, "icon": None}


def case(**over):
    row = {"case_id": 49, "body": "they keep sending me messages", "assignees": [],
           "resolved_at": None, "resolution": None, "url": "https://fe/cases/49"}
    row.update(over)
    return row


def entry(**over):
    row = {"type_key": "shush", "target_user_id": "USUBJECT", "expires_at": None, "reason": "spam",
           "performed_by": "UMOD", "performed_at": AT, "channel_id": None}
    row.update(over)
    return row


def note(**over):
    row = {"author": "UMOD", "body": "likely an alternate", "created_at": AT}
    row.update(over)
    return row


def thread(**over):
    row = {"channel_id": "C0LOUNGE", "thread_ts": "1762790400.123456"}
    row.update(over)
    return row


def build(row=None, reporter=NAMED, entries=(), notes=(), **kwargs):
    return case_view.build_view(row or case(), reporter, list(entries), list(notes), **kwargs)


def block_types(view):
    return [one["type"] for one in view["blocks"]]


def texts(view):
    return [str(one) for one in view["blocks"]]


def test_build_view_sets_modal_identity():
    view = build()

    assert view["type"] == "modal"
    assert view["callback_id"] == case_view.CALLBACK
    assert view["private_metadata"] == "49"
    assert view["title"]["text"] == "Case 49"
    assert view["close"]["text"] == "Close"


def test_card_block_named_reporter_uses_mention_and_icon():
    card = case_view.card_block(case(), NAMED)

    assert card["title"]["text"] == "<@UREPORTER>"
    assert card["icon"]["image_url"] == "https://img/reporter.png"


def test_card_block_anonymous_reporter_has_no_icon_or_name():
    card = case_view.card_block(case(), ANONYMOUS)

    assert card["title"]["text"] == "Anonymous"
    assert "icon" not in card


def test_card_block_without_reporter_titles_with_case_number():
    card = case_view.card_block(case(), {"anonymous": False, "user_id": None, "icon": None})

    assert card["title"]["text"] == "Case 49"


def test_card_block_has_no_subtitle_or_subtext():
    card = case_view.card_block(case(), NAMED)

    assert "subtitle" not in card and "subtext" not in card


def test_card_block_body_quotes_report():
    assert case_view.card_block(case(), NAMED)["body"]["text"] == "> they keep sending me messages"


def test_card_block_without_body_omits_body():
    assert "body" not in case_view.card_block(case(body=None), NAMED)


def test_card_block_buttons_follow_case_state():
    open_ids = [one["action_id"] for one in case_view.card_block(case(), NAMED)["actions"]]
    resolved = case(resolved_at=AT, resolution="no_action")
    resolved_ids = [one["action_id"] for one in case_view.card_block(resolved, NAMED)["actions"]]

    assert open_ids == [case_card.LOG_ACTION, case_card.MORE, case_card.CLAIM]
    assert resolved_ids == [case_card.MORE, case_card.REOPEN]


def test_quoted_long_body_fits_card_limit():
    rendered = case_view.quoted("word " * 200)

    assert len(rendered) <= case_view.BODY_LIMIT
    assert rendered.endswith(case_view.TRUNCATED)


def test_quoted_escapes_markup_inside_limit():
    rendered = case_view.quoted("&<>" * 100)

    assert len(rendered) <= case_view.BODY_LIMIT
    assert "<>" not in rendered


def test_quoted_keeps_member_token_whole():
    rendered = case_view.quoted("x" * 185 + " <@UABCDEFGH> trailing words")

    body = rendered.removeprefix("> ")

    assert body.count("<") == body.count(">")


def test_quoted_blank_body_returns_none():
    assert case_view.quoted("  \n ") is None


def test_assignee_line_lists_mentions():
    assert case_view.assignee_line(["UA", "UB"]) == "Assignees: <@UA>, <@UB>"


def test_assignee_line_without_assignees_says_unassigned():
    assert case_view.assignee_line([]) == "Unassigned"


def test_assignee_line_over_limit_counts_remainder():
    line = case_view.assignee_line([f"U{one:03d}" for one in range(12)])

    assert line.endswith("2 more")


def test_build_view_assignees_context_comes_before_card():
    view = build(case(assignees=["UA"]))

    assert block_types(view)[:2] == ["context", "card"]
    assert view["blocks"][0]["elements"][0]["text"] == "Assignees: <@UA>"


def test_build_view_without_actions_or_notes_omits_sections():
    view = build()

    assert "header" not in block_types(view)


def test_build_view_lists_actions_with_target_reason_and_actor():
    view = build(entries=[entry()])
    text = "\n".join(texts(view))

    assert "*Shush*  <@USUBJECT>" in text
    assert "spam" in text
    assert "<@UMOD>" in text


def test_action_text_channel_ban_names_channel_and_end():
    text = case_view.action_text(entry(type_key="channel_ban", channel_id="CLOUNGE", expires_at=AT))

    assert " in <#CLOUNGE>" in text
    assert f"ends {short_end(AT)}" in text


def test_action_text_escapes_reason():
    assert "&lt;b&gt;" in case_view.action_text(entry(reason="<b>"))


def test_build_view_shows_newest_actions_and_counts_rest():
    entries = [entry(target_user_id=f"U{one:03d}") for one in range(case_view.ACTIONS_SHOWN + 2)]

    view = build(entries=entries)
    text = "\n".join(texts(view))

    assert "U000" not in text and f"U{case_view.ACTIONS_SHOWN + 1:03d}" in text
    assert "2 more in Fire Engine" in text


def test_build_view_lists_notes_with_author_and_body():
    text = "\n".join(texts(build(notes=[note()])))

    assert "*<@UMOD>*" in text and "likely an alternate" in text


def test_thread_text_names_channel_links_thread_and_posted_time():
    posted = dt.datetime(2025, 11, 10, 16, 0, tzinfo=dt.UTC)

    assert case_view.thread_text(thread()) == (
        "<#C0LOUNGE>  <https://hackclub.slack.com/archives/C0LOUNGE/p1762790400123456|Open thread>\n"
        f"_<!date^1762790400^{{ago}}|{short_end(posted)}>_"
    )


def test_build_view_lists_slack_threads_after_notes():
    view = build(entries=[entry()], notes=[note()], threads=[thread()])

    headers = [one["text"]["text"] for one in view["blocks"] if one["type"] == "header"]
    position = next(at for at, one in enumerate(view["blocks"])
                    if one["type"] == "header" and one["text"]["text"] == "Slack threads")
    assert headers == ["Actions", "Notes", "Slack threads"]
    assert "Open thread>" in view["blocks"][position + 1]["text"]["text"]


def test_build_view_without_threads_omits_threads_section():
    view = build(notes=[note()])

    assert [one["text"]["text"] for one in view["blocks"] if one["type"] == "header"] == ["Notes"]


def test_build_view_shows_newest_threads_and_links_rest_to_threads_tab():
    threads = [thread(channel_id=f"C{one:03d}") for one in range(case_view.THREADS_SHOWN + 2)]

    text = "\n".join(texts(build(threads=threads)))

    assert "<#C000>" not in text and f"<#C{case_view.THREADS_SHOWN + 1:03d}>" in text
    assert "<https://fe/cases/49?tab=threads|2 more in Fire Engine>" in text


def test_build_view_notice_is_first_block():
    view = build(notice="Case 49 is already open")

    assert view["blocks"][0]["elements"][0]["text"] == "Case 49 is already open"


def test_build_view_footer_links_thread_and_fire_engine():
    view = build(thread_url="https://slack/thread")
    footer = view["blocks"][-1]["elements"][0]["text"]

    assert "<https://slack/thread|Open thread>" in footer
    assert "<https://fe/cases/49|Open in Fire Engine>" in footer


def test_build_view_without_links_has_no_footer():
    view = build(case(url=None))

    assert view["blocks"][-1]["type"] == "card"


def test_build_view_text_sections_fit_slack_limits():
    entries = [entry(reason="r" * 2000) for _ in range(case_view.ACTIONS_SHOWN)]
    notes = [note(body="n" * 2000) for _ in range(case_view.NOTES_SHOWN)]

    view = build(entries=entries, notes=notes)

    assert all(len(one["text"]["text"]) <= 3000 for one in view["blocks"] if one["type"] == "section")
    assert len(view["blocks"]) <= 100
