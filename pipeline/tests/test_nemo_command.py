import datetime as dt

import pytest

from bot.nemo import command

USER_ID = "U1ABC"
CHANNEL_ID = "C1LOUNGE"
USER_MENTION = f"<@{USER_ID}|somebody>"
CHANNEL_MENTION = f"<#{CHANNEL_ID}|lounge>"


def test_parse_command_shush_returns_verb_target_and_body():
    verb, target, body = command.parse_command(f"shush {USER_MENTION} 3d flooding the channel")

    assert (verb, target, body) == (command.SHUSH, USER_ID, "3d flooding the channel")


def test_needed_shush_requires_member_guard():
    assert command.NEEDED[command.SHUSH] == "member.guard"


NOW = dt.datetime(2026, 10, 16, 9, 30, tzinfo=dt.UTC)


@pytest.mark.parametrize(("text", "length"), [
    ("30m", dt.timedelta(minutes=30)),
    ("2h", dt.timedelta(hours=2)),
    ("3d", dt.timedelta(days=3)),
    ("2w", dt.timedelta(weeks=2)),
    ("1D", dt.timedelta(days=1)),
])
def test_parse_end_length_adds_to_now(text, length):
    assert command.parse_end(text, NOW) == NOW + length


def test_parse_end_date_returns_end_of_day():
    assert command.parse_end("2026-11-20", NOW) == dt.datetime(2026, 11, 20, 23, 59, 59, tzinfo=dt.UTC)


@pytest.mark.parametrize("text", ["0m", "366d", "53w", "soon", "", "-3d", "2026-13-01",
                                  "2026-10-16", "2026-10-15", "2027-12-01"])
def test_parse_end_out_of_range_returns_none(text):
    assert command.parse_end(text, NOW) is None


def test_parse_end_and_reason_splits_length_from_reason():
    assert command.parse_end_and_reason("2w  flooding   #lounge", NOW) == \
        (True, NOW + dt.timedelta(weeks=2), "flooding #lounge")


def test_parse_end_and_reason_without_length_returns_no_end():
    assert command.parse_end_and_reason("flooding the channel", NOW) == (True, None, "flooding the channel")


def test_parse_end_and_reason_number_in_reason_returns_no_end():
    assert command.parse_end_and_reason("3 spam messages", NOW) == (True, None, "3 spam messages")


def test_parse_end_and_reason_bad_length_returns_invalid():
    assert command.parse_end_and_reason("400d spamming", NOW) == (False, None, "spamming")


def test_parse_end_and_reason_length_only_returns_no_reason():
    assert command.parse_end_and_reason("3d", NOW) == (True, NOW + dt.timedelta(days=3), None)


def test_shush_confirmation_without_end_shows_no_end_date():
    assert command.shush_confirmation("U1", None, "spamming") == \
        "<@U1> has been shushed with no end date. Reason: spamming"


def test_ban_confirmation_with_time_shows_utc_time():
    assert command.ban_confirmation("U1", "C1", dt.datetime(2026, 10, 16, 11, 30, tzinfo=dt.UTC), "spamming") == \
        "<@U1> has been banned from <#C1> until 16 Oct, 11:30 UTC. Reason: spamming"


def test_parse_command_channelban_returns_verb_target_and_body():
    verb, target, body = command.parse_command(f"channelban {USER_MENTION} {CHANNEL_MENTION} 3d flooding it")

    assert (verb, target, body) == (command.CHANNEL_BAN, USER_ID, f"{CHANNEL_MENTION} 3d flooding it")


def test_needed_channel_ban_requires_member_guard():
    assert command.NEEDED[command.CHANNEL_BAN] == "member.guard"


def test_extract_channel_mention_at_start_or_end_returns_channel_and_rest():
    assert command.extract_channel(f"{CHANNEL_MENTION} 3d flooding it") == (CHANNEL_ID, "3d flooding it")
    assert command.extract_channel(f"3d flooding {CHANNEL_MENTION}") == (CHANNEL_ID, "3d flooding")


def test_extract_channel_without_mention_returns_none():
    assert command.extract_channel("3d flooding it") == (None, None)
    assert command.extract_channel("3d flooding #lounge") == (None, None)


def test_parse_end_and_reason_after_extract_channel_parses_remainder():
    channel_id, remainder = command.extract_channel(f"{CHANNEL_MENTION} 2w flooding it")

    assert channel_id == CHANNEL_ID
    assert command.parse_end_and_reason(remainder, NOW) == (True, NOW + dt.timedelta(weeks=2), "flooding it")


def test_fallback_text_lists_shush_only_with_member_guard():
    help_text = command.helping.fallback_text({"member.guard"})

    assert "/nemo shush" in help_text
    assert "/nemo channelban" in help_text
    assert "/nemo shush" not in command.helping.fallback_text({"case.read"})


def test_parse_command_slowmode_returns_no_target_and_full_body():
    verb, target, body = command.parse_command(f"slowmode {CHANNEL_MENTION} 30s 2h heated thread")

    assert (verb, target, body) == (command.SLOWMODE, None, f"{CHANNEL_MENTION} 30s 2h heated thread")


def test_needed_slowmode_requires_channel_guard():
    assert command.NEEDED[command.SLOWMODE] == "channel.guard"


@pytest.mark.parametrize(("text", "seconds"), [("30s", 30), ("30", 30), ("2m", 120), ("3600", 3600),
                                               ("0s", None), ("3601", None), ("61m", None), ("fast", None)])
def test_cooldown_of_parses_seconds_and_minutes(text, seconds):
    assert command.cooldown_of(text) == seconds


def test_slowmode_request_channel_and_duration_returns_request():
    request, problem = command.slowmode_request(f"{CHANNEL_MENTION} 30s 2h heated thread", "CHERE", NOW)

    assert problem is None
    assert request == {"channel_id": CHANNEL_ID, "off": False, "seconds": 30,
                       "expires_at": NOW + dt.timedelta(hours=2), "reason": "heated thread"}


def test_slowmode_request_without_duration_has_no_end():
    request, _problem = command.slowmode_request(f"{CHANNEL_MENTION} 45s heated thread", "CHERE", NOW)

    assert (request["seconds"], request["expires_at"], request["reason"]) == (45, None, "heated thread")


def test_slowmode_request_without_channel_uses_current_channel():
    request, _problem = command.slowmode_request("1m heated", "CHERE", NOW)

    assert request["channel_id"] == "CHERE"


def test_slowmode_request_in_dm_returns_usage():
    assert command.slowmode_request("30s heated", "D123", NOW) == (None, command.TEXT_USAGE[command.SLOWMODE])


def test_slowmode_request_off_returns_off_request():
    assert command.slowmode_request(f"{CHANNEL_MENTION} off", "CHERE", NOW) == \
        ({"channel_id": CHANNEL_ID, "off": True}, None)


@pytest.mark.parametrize(("body", "problem"), [
    (f"{CHANNEL_MENTION} soon heated", command.COOLDOWN_USAGE),
    (f"{CHANNEL_MENTION} 30s 400d heated", command.DURATION_USAGE[command.SLOWMODE]),
    (f"{CHANNEL_MENTION} 30s 2h", command.SLOWMODE_REASON_USAGE),
])
def test_slowmode_request_bad_input_returns_usage(body, problem):
    assert command.slowmode_request(body, "CHERE", NOW) == (None, problem)


@pytest.fixture
def channel_guard_calls(monkeypatch):
    calls = {"row": None, "opened": [], "updated": [], "lifted": []}
    monkeypatch.setattr(command.channelguards, "slowmode_row", lambda conn, channel_id: calls["row"])
    monkeypatch.setattr(command.channelguards, "open_slowmode",
                        lambda conn, *args, **kwargs: calls["opened"].append((args, kwargs)) or 5)
    monkeypatch.setattr(command.channelguards, "update_slowmode",
                        lambda conn, row, *args: calls["updated"].append(args) or row["id"])
    monkeypatch.setattr(command.channelguards, "lift",
                        lambda conn, guard_id, by: calls["lifted"].append(guard_id) or CHANNEL_ID)
    return calls


def request_for(**over):
    row = {"channel_id": CHANNEL_ID, "off": False, "seconds": 30, "expires_at": None, "reason": "heated"}
    row.update(over)
    return row


def test_apply_slowmode_new_opens_guard_with_notice(channel_guard_calls):
    reply = command.apply_slowmode(object(), request_for(), "UMOD")

    assert channel_guard_calls["opened"] == [((CHANNEL_ID, "", 30, "UMOD", "heated", None), {"notice_wanted": True})]
    assert reply is None


def test_apply_slowmode_existing_row_updates_guard(channel_guard_calls):
    channel_guard_calls["row"] = {"id": 9, "seconds": 60, "expires_at": None, "reason": "old"}

    reply = command.apply_slowmode(object(), request_for(seconds=120), "UMOD")

    assert channel_guard_calls["updated"] == [(120, "UMOD", "heated", None)]
    assert reply is None


def test_apply_slowmode_off_lifts_guard_or_reports_none(channel_guard_calls):
    assert command.apply_slowmode(object(), request_for(off=True), "UMOD") == f"No slow mode in <#{CHANNEL_ID}>"

    channel_guard_calls["row"] = {"id": 9}
    assert command.apply_slowmode(object(), request_for(off=True), "UMOD") == \
        f"Slow mode disabled in <#{CHANNEL_ID}>"
    assert channel_guard_calls["lifted"] == [9]


def test_fallback_text_lists_slowmode_only_with_channel_guard():
    assert "/nemo slowmode" in command.helping.fallback_text({"channel.guard"})
    assert "/nemo slowmode" not in command.helping.fallback_text({"member.guard"})


def test_parse_command_unshush_and_unban_return_member_target():
    assert command.parse_command(f"unshush {USER_MENTION}") == (command.UNSHUSH, USER_ID, None)
    assert command.parse_command(f"unban {USER_MENTION} {CHANNEL_MENTION} appeal upheld") == \
        (command.UNBAN, USER_ID, f"{CHANNEL_MENTION} appeal upheld")


def test_needed_unshush_and_unban_require_member_guard():
    assert command.NEEDED[command.UNSHUSH] == command.NEEDED[command.UNBAN] == "member.guard"


@pytest.fixture
def member_guards(monkeypatch):
    state = {"guard": {"id": 7, "state": "live"}, "lookups": [], "lifted": []}
    monkeypatch.setattr(command.memberguards, "active_guard",
                        lambda conn, user_id, kind, channel_id=None:
                        state["lookups"].append((user_id, kind, channel_id)) or state["guard"])
    monkeypatch.setattr(command.memberguards, "lift",
                        lambda conn, guard_id, by, why, kind=None:
                        state["lifted"].append((guard_id, by, why, kind)) or True)
    return state


def test_unshush_live_shush_lifts_guard(member_guards):
    assert command.unshush(object(), USER_ID, None, "UMOD") == f"<@{USER_ID}> has been unshushed"
    assert member_guards["lookups"] == [(USER_ID, "shush", None)]
    assert member_guards["lifted"] == [(7, "UMOD", None, "shush")]


def test_unshush_with_reason_includes_reason(member_guards):
    assert command.unshush(object(), USER_ID, "appeal upheld", "UMOD") == \
        f"<@{USER_ID}> has been unshushed. Reason: appeal upheld"


def test_unshush_without_shush_reports_not_shushed(member_guards):
    member_guards["guard"] = None

    assert command.unshush(object(), USER_ID, None, "UMOD") == f"<@{USER_ID}> is not shushed"
    assert member_guards["lifted"] == []


def test_unban_with_channel_lifts_channel_ban(member_guards):
    reply = command.unban(object(), USER_ID, f"{CHANNEL_MENTION} appeal upheld", "UMOD")

    assert reply == f"<@{USER_ID}> has been unbanned from <#{CHANNEL_ID}>. Reason: appeal upheld"
    assert member_guards["lookups"] == [(USER_ID, "channel_ban", CHANNEL_ID)]
    assert member_guards["lifted"] == [(7, "UMOD", "appeal upheld", "channel_ban")]


@pytest.fixture
def reactivating(monkeypatch):
    state = {"may": (True, None), "outcome": ("queued", [11, 12]), "calls": []}
    monkeypatch.setattr(command.access, "may", lambda conn, user_id, key, case_id=None: state["may"])

    def reactivate(conn, user_id, by, why):
        state["calls"].append((user_id, by, why))
        return state["outcome"]

    monkeypatch.setattr(command.reactivation, "reactivate", reactivate)
    return state


def test_unban_without_channel_reactivates_the_account_and_ends_its_bans(reactivating, member_guards):
    reply = command.unban(object(), USER_ID, "appeal accepted", "UMOD")

    assert reply == f"<@{USER_ID}> reactivation queued · 2 bans ended. Reason: appeal accepted"
    assert reactivating["calls"] == [(USER_ID, "UMOD", "appeal accepted")]
    assert member_guards["lifted"] == []


def test_unban_without_channel_needs_member_deactivate(reactivating, member_guards):
    reactivating["may"] = (False, "You need member.deactivate")

    assert command.unban(object(), USER_ID, None, "UMOD") == "You need member.deactivate"
    assert reactivating["calls"] == []


@pytest.mark.parametrize(("outcome", "reply"), [
    (("nothing", []), f"<@{USER_ID}> is not deactivated"),
    (("firehose", []), f"<@{USER_ID}> is deactivated in Firehose"),
    (("lifted", []), f"<@{USER_ID}> deactivation lifted"),
    (("nothing", [11]), f"<@{USER_ID}> bans ended"),
])
def test_unban_without_channel_reports_each_outcome(reactivating, outcome, reply):
    reactivating["outcome"] = outcome

    assert command.unban(object(), USER_ID, None, "UMOD") == reply


def test_unban_without_ban_reports_not_banned(member_guards):
    member_guards["guard"] = None

    assert command.unban(object(), USER_ID, CHANNEL_MENTION, "UMOD") == \
        f"<@{USER_ID}> is not banned from <#{CHANNEL_ID}>"


def test_fallback_text_lists_unshush_and_unban():
    help_text = command.helping.fallback_text({"member.guard"})

    assert "/nemo unshush" in help_text
    assert "/nemo unban" in help_text


@pytest.mark.parametrize(("text", "parsed"), [
    ("lookup U0123ABCD", (command.LOOKUP, "U0123ABCD", None)),
    ("note W0123ABCD  spammed  again", (command.NOTE, "W0123ABCD", "spammed again")),
    ("shush U0123ABCD 3d flooding", (command.SHUSH, "U0123ABCD", "3d flooding")),
    ("open U0123ABCD alt account", (command.OPEN, "U0123ABCD", "alt account")),
    ("purge U0123ABCD", (command.PURGE, "U0123ABCD", None)),
])
def test_parse_command_bare_user_id_returns_target(text, parsed):
    assert command.parse_command(text) == parsed


@pytest.mark.parametrize(("text", "parsed"), [
    ("open URGENT raid in lounge", (command.OPEN, None, "URGENT raid in lounge")),
    ("lookup U12", (command.LOOKUP, None, "U12")),
    ("note u0123abcd text", (command.NOTE, None, "u0123abcd text")),
    ("note spammed by U0123ABCD", (command.NOTE, None, "spammed by U0123ABCD")),
    ("slowmode U0123ABCD 30s", (command.SLOWMODE, None, "U0123ABCD 30s")),
])
def test_parse_command_non_leading_user_id_returns_no_target(text, parsed):
    assert command.parse_command(text) == parsed


def test_parse_command_mention_overrides_bare_user_id():
    assert command.parse_command("note U0123ABCD about <@U9999ZZZZ>") == \
        (command.NOTE, "U9999ZZZZ", "U0123ABCD about")
