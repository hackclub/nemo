import datetime as dt

from bot.nemo import command

WHO = "U1ABC"
ROOM = "C1LOUNGE"
SAID = f"<@{WHO}|somebody>"
THERE = f"<#{ROOM}|lounge>"


def test_shush_is_asked_for_like_the_other_verbs():
    verb, wanted, body = command.asked(f"shush {SAID} 3d flooding the channel")

    assert (verb, wanted, body) == (command.SHUSH, WHO, "3d flooding the channel")


def test_shush_needs_the_member_guard_capability():
    assert command.NEEDED[command.SHUSH] == "member.guard"


def test_days_and_weeks_both_read_as_a_date():
    today = dt.date.today()

    assert command.ends_on("3d") == today + dt.timedelta(days=3)
    assert command.ends_on("2w") == today + dt.timedelta(days=14)
    assert command.ends_on("1D") == today + dt.timedelta(days=1)


def test_a_date_is_taken_as_it_stands():
    on = dt.date.today() + dt.timedelta(days=40)

    assert command.ends_on(on.strftime("%Y-%m-%d")) == on


def test_what_is_not_a_length_reads_as_none():
    for said in ("0d", "999d", "soon", "", "2026-13-01", "-3d"):
        assert command.ends_on(said) is None, said


def test_a_date_already_gone_reads_as_none():
    gone = dt.date.today() - dt.timedelta(days=1)

    assert command.ends_on(gone.strftime("%Y-%m-%d")) is None


def test_the_length_is_split_off_the_reason():
    on, why = command.for_how_long("2w  flooding   #lounge")

    assert on == dt.date.today() + dt.timedelta(days=14)
    assert why == "flooding #lounge"


def test_a_reason_with_no_length_is_held_back():
    assert command.for_how_long("flooding the channel") == (None, None)


def test_a_length_with_no_reason_leaves_nothing_to_write_down():
    on, why = command.for_how_long("3d")

    assert on == dt.date.today() + dt.timedelta(days=3)
    assert why is None


def test_channelban_is_asked_for_like_the_other_verbs():
    verb, wanted, body = command.asked(f"channelban {SAID} {THERE} 3d flooding it")

    assert (verb, wanted, body) == (command.CHANNEL_BAN, WHO, f"{THERE} 3d flooding it")


def test_channelban_needs_the_member_guard_capability():
    assert command.NEEDED[command.CHANNEL_BAN] == "member.guard"


def test_the_channel_is_split_off_wherever_it_was_said():
    assert command.in_a_channel(f"{THERE} 3d flooding it") == (ROOM, "3d flooding it")
    assert command.in_a_channel(f"3d flooding {THERE}") == (ROOM, "3d flooding")


def test_a_ban_with_no_channel_is_held_back():
    assert command.in_a_channel("3d flooding it") == (None, None)
    assert command.in_a_channel("3d flooding #lounge") == (None, None)


def test_the_length_still_reads_after_the_channel_comes_out():
    where, rest = command.in_a_channel(f"{THERE} 2w flooding it")
    on, why = command.for_how_long(rest)

    assert where == ROOM
    assert on == dt.date.today() + dt.timedelta(days=14)
    assert why == "flooding it"


def test_the_help_card_lists_shush_only_for_who_holds_it():
    shown = command.helping.flat({"member.guard"})

    assert "/nemo shush" in shown
    assert "/nemo channelban" in shown
    assert "/nemo shush" not in command.helping.flat({"case.read"})
