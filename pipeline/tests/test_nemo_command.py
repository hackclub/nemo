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
    assert command.asked("3864") == ("case", 3864)
    assert command.asked(" #3864 ") == ("case", 3864)


def test_a_lookup_needs_an_escaped_mention():
    assert command.asked("lookup <@U0QUINN>") == (command.LOOKUP, "U0QUINN")
    assert command.asked("lookup <@U0QUINN|old-handle>") == (command.LOOKUP, "U0QUINN")
    assert command.asked("LOOKUP <@W0BOSS>") == (command.LOOKUP, "W0BOSS")


def test_a_lookup_with_an_unescaped_name_names_nobody():
    assert command.asked("lookup @quinn27") == (command.LOOKUP, None)


def test_anything_else_gets_the_help():
    for said in ("", None, "   ", "resolve 3864", "who @them"):
        assert command.asked(said) == (None, None)


def test_the_help_says_only_what_it_can_do():
    assert "/nemo lookup" in command.HELP
    assert "/nemo 3864" in command.HELP


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
