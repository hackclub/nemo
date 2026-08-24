from datetime import datetime

from bot.nemo import command, record

WHEN = datetime(2026, 8, 12, 14, 9)


def a_record(entries=(), total=None, in_force=None, **counts):
    tally = {"subject_of": 3, "logged_in": 6, "live": 1, "reversed": 0}
    tally.update(counts)
    return {
        "user_id": "UQUINN",
        "counts": tally,
        "in_force": in_force,
        "total": total if total is not None else len(entries),
        "entries": list(entries),
    }


def a_case_entry(**over):
    base = {
        "at": WHEN,
        "kind": "cases",
        "case_id": 3864,
        "what": "bullying",
        "who_by": None,
        "said": None,
    }
    base.update(over)
    return base


def text_of(answer):
    said = []
    for block in answer["blocks"]:
        if block["type"] == "section":
            said.append(block["text"]["text"])
        elif block["type"] == "context":
            said.extend(e["text"] for e in block["elements"])
        elif block["type"] == "rich_text":
            for group in block["elements"]:
                for item in group["elements"]:
                    said.append(
                        "".join(
                            f"<@{part['user_id']}>"
                            if part["type"] == "user"
                            else f"<#{part['channel_id']}>"
                            if part["type"] == "channel"
                            else part["text"]
                            for part in item["elements"]
                        )
                    )
    return "\n".join(said)


def test_a_case_number_is_understood_bare_or_hashed():
    assert command.asked("3864") == ("case", 3864, None)
    assert command.asked(" #3864 ") == ("case", 3864, None)


def test_a_lookup_needs_an_escaped_mention():
    assert command.asked("lookup <@U0QUINN>") == (command.LOOKUP, "U0QUINN", None)
    assert command.asked("lookup <@U0QUINN|old-handle>") == (command.LOOKUP, "U0QUINN", None)
    assert command.asked("LOOKUP <@W0BOSS>") == (command.LOOKUP, "W0BOSS", None)


def test_a_lookup_with_an_unescaped_name_names_nobody():
    assert command.asked("lookup @quinn27") == (command.LOOKUP, None, None)


def test_anything_else_gets_the_help():
    for said in ("", None, "   ", "resolve 3864", "who @them"):
        assert command.asked(said) == (None, None, None)


def test_the_help_says_only_what_it_can_do():
    for verb in ("/nemo lookup", "/nemo note", "/nemo open", "/nemo 3864"):
        assert verb in command.HELP
    for never in ("resolve", "ban", "act"):
        assert never not in command.HELP


def test_a_note_keeps_the_words_and_drops_the_mention_that_named_them():
    assert command.asked("note <@U0QUINN> spoke to them in a DM") == (
        command.NOTE,
        "U0QUINN",
        "spoke to them in a DM",
    )


def test_the_words_can_sit_either_side_of_the_name_and_close_up_after_it():
    assert command.asked("open going after <@U0QUINN> all week") == (
        command.OPEN,
        "U0QUINN",
        "going after all week",
    )


def test_a_second_mention_stays_in_the_words():
    verb, who, body = command.asked("note <@U0QUINN> was rude to <@U0MILO>")
    assert (verb, who) == (command.NOTE, "U0QUINN")
    assert body == "was rude to <@U0MILO>"


def test_a_write_with_no_words_is_asked_for_them():
    assert command.asked("note <@U0QUINN>") == (command.NOTE, "U0QUINN", None)
    assert command.asked("open <@U0QUINN>   ") == (command.OPEN, "U0QUINN", None)
    assert command.NOTE in command.NEEDS_WORDS
    assert command.OPEN in command.NEEDS_WORDS
    assert command.LOOKUP not in command.NEEDS_WORDS


def test_every_verb_is_gated_on_the_permission_the_dashboard_uses():
    assert command.NEEDED == {
        command.LOOKUP: "identity.read",
        command.NOTE: "member.note",
        command.OPEN: "case.open",
        "case": "case.read",
    }


def test_an_open_case_about_them_is_named_rather_than_doubled():
    said = command.already_open("U0QUINN", [3864])
    assert "<@U0QUINN> already has an open case, *case 3864*" in said
    assert "Add what you found to that one instead." in said

    assert "*case 3864*, *case 3900*" in command.already_open("U0QUINN", [3864, 3900])


def test_opening_says_what_was_opened_and_about_whom():
    assert command.opened(3949, "U0QUINN", "going after the new kids") == (
        "*case 3949* opened about <@U0QUINN>"
    )
    assert "nothing written on it yet" in command.opened(3949, "U0QUINN", None)


def test_the_record_leads_with_the_person_and_what_is_in_force():
    said = text_of(command.looked_up(a_record()))

    assert "*<@UQUINN>*  ·  nothing standing" in said
    assert "subject of 3  ·  logged in 6  ·  1 action" in said


def test_a_reversal_count_only_shows_when_there_is_one():
    assert "reversed" not in text_of(command.looked_up(a_record()))
    assert "2 reversed" in text_of(command.looked_up(a_record(reversed=2)))


def test_what_is_in_force_names_the_channel_and_the_date():
    found = a_record(
        in_force={
            "type_key": "channel_ban",
            "expires_at": datetime(2026, 9, 3),
            "details": {"channel_id": "C0LOUNGE"},
        }
    )
    assert "channel ban in <#C0LOUNGE> until 3 Sep" in text_of(command.looked_up(found))


def test_a_ban_with_no_end_says_so():
    found = a_record(in_force={"type_key": "perma_ban", "expires_at": None, "details": None})
    assert "permanent ban, no end date" in text_of(command.looked_up(found))


def test_every_kind_of_entry_reads_as_a_line():
    entries = [
        a_case_entry(),
        a_case_entry(who_by="action_taken"),
        a_case_entry(kind="actions", what="shush", who_by="UFF1"),
        a_case_entry(kind="reversed", what="shush", who_by="UFF2", said="appeal upheld"),
        a_case_entry(kind="notes", case_id=None, what=None, who_by="UFF1", said="spoke to them"),
    ]
    said = text_of(command.looked_up(a_record(entries)))

    assert "12 Aug 2026  ·  case 3864, bullying, open" in said
    assert "12 Aug 2026  ·  case 3864, bullying, action taken" in said
    assert "12 Aug 2026  ·  shush on case 3864, by <@UFF1>" in said
    assert "12 Aug 2026  ·  shush reversed by <@UFF2>, appeal upheld" in said
    assert "12 Aug 2026  ·  note by <@UFF1>: spoke to them" in said


def test_the_record_is_a_bulleted_list_not_a_wall_of_text():
    answer = command.looked_up(a_record([a_case_entry(), a_case_entry(case_id=3831)]))
    lists = [b for b in answer["blocks"] if b["type"] == "rich_text"]

    assert len(lists) == 1
    assert lists[0]["elements"][0]["style"] == "bullet"
    assert len(lists[0]["elements"][0]["elements"]) == 2


def test_a_truncated_record_says_how_much_it_is_hiding():
    said = text_of(command.looked_up(a_record([a_case_entry()] * 8, total=34)))
    assert "showing 8 of 34" in said


def test_an_empty_record_says_so_plainly():
    said = text_of(command.looked_up(a_record(subject_of=0, logged_in=0, live=0)))

    assert "Nothing on their record at all." in said
    assert "showing" not in said


def test_the_link_out_is_dropped_when_there_is_no_host(monkeypatch):
    monkeypatch.delenv("APP_HOST", raising=False)
    answer = command.looked_up(a_record())
    assert not [b for b in answer["blocks"] if b["type"] == "actions"]


def test_the_link_out_points_at_their_page(monkeypatch):
    monkeypatch.setenv("APP_HOST", "nemo.hackclub.com")
    acting = [b for b in command.looked_up(a_record())["blocks"] if b["type"] == "actions"][0]

    assert acting["elements"][0]["url"] == "https://nemo.hackclub.com/fd/members/UQUINN"


def test_the_worst_action_is_asked_for_first():
    assert record.worst_first()[0] == "perma_ban"
    assert record.worst_first()[-1] == "dm"
