USER_CAPABILITIES = "SELECT capability FROM app.effective_capability WHERE user_id = %s"

GRANTERS = """
SELECT user_id FROM app.effective_capability WHERE capability = 'access.grant'
ORDER BY user_id
"""

HEADER = "Commands"

NO_ACCESS = "You have no Fire Department access. Ask {who}."

NO_ACCESS_NO_GRANTERS = "You have no Fire Department access. Ask a community manager."

LOOKUP = (
    "Lookup",
    (
        ("case.read", "/nemo lookup @member", "their record"),
        ("case.read", "/nemo mentions @member", "messages mentioning them in Fire Department channels"),
        ("case.read", "/nemo 3864", "show case 3864"),
        ("case.read", "/nemo queue", "open cases"),
    ),
)

NOTES = (
    "Notes and cases",
    (
        ("member.note", "/nemo note @member text", "member note, shown on every case"),
        ("case.open", "/nemo open @member summary", "open a case"),
        ("case.resolve", "/nemo merge 23 25", "close 25 as a duplicate of 23"),
    ),
)

GUARDS = (
    "Shush and channel ban",
    (
        ("member.guard", "/nemo shush @member 3d reason", "shush for 3 days, no case"),
        ("member.guard", "/nemo shush @member 2h reason", "shush for 2 hours, no case"),
        ("member.guard", "/nemo shush @member reason", "shush with no end date, no case"),
        ("member.guard", "/nemo unshush @member", "lift a shush"),
        ("member.guard", "/nemo channelban @member #channel 3d reason",
         "channel ban for 3 days, no case"),
        ("member.guard", "/nemo unban @member #channel", "lift a channel ban"),
        ("member.deactivate", "/nemo unban @member reason", "reactivate an account and end its bans"),
    ),
)

SLOWMODE = (
    "Slow mode",
    (
        ("channel.guard", "/nemo slowmode #channel 30s 2h reason", "30s cooldown for 2 hours"),
        ("channel.guard", "/nemo slowmode #channel 30s reason", "30s cooldown with no end date"),
        ("channel.guard", "/nemo slowmode #channel off", "disable slow mode"),
    ),
)

CHANNEL_GUARDS = (
    "Channel guards",
    (
        ("channel.guard", "/nemo readonly #channel on", "read-only"),
        ("channel.guard", "/nemo readonly #channel on threads", "read-only, threads included"),
        ("channel.guard", "/nemo readonly #channel allow @member", "allow a member"),
        ("channel.guard", "/nemo readonly #channel off", "turn read-only off"),
        ("channel.guard", "/nemo accountage #channel 7d", "minimum account age"),
        ("channel.guard", "/nemo accountage #channel allow @member", "allow a member"),
        ("channel.guard", "/nemo accountage #channel off", "turn the age limit off"),
        ("channel.guard", "/nemo botallow #channel on", "bot allow list"),
        ("channel.guard", "/nemo botallow #channel add @bot", "allow a bot"),
        ("channel.guard", "/nemo botallow #channel remove @bot", "remove a bot"),
        ("channel.guard", "/nemo botallow #channel off", "turn the allow list off"),
        ("channel.guard", "/nemo readonly #channel", "state and allow list"),
    ),
)

PURGE = (
    "Purge",
    (
        ("channel.purge", "/nemo purge 50", "last 50 messages in this channel, with thread replies"),
        ("channel.purge", "/nemo purge #channel 50", "last 50 messages in that channel"),
        ("member.purge", "/nemo purge @member", "all their messages in every channel"),
        ("member.purge", "/nemo purge @member #channel", "all their messages in that channel"),
    ),
)

THREAD = (
    "In a case thread",
    (
        ("case.reply", "?text", "reply to the reporter with your name"),
        ("case.reply", "~?text", "reply to the reporter without your name"),
        ("case.read", "!case", "case link"),
        ("case.open", "!claim", "assign yourself"),
        ("case.open", "!assign @user", "assign someone"),
        ("case.open", "!unassign @user", "unassign someone"),
        ("case.note", "!note text", "case note"),
        ("member.note", "!note @member text", "member note"),
        ("case.resolve", "!resolve", "resolve and notify the reporter"),
    ),
)

CARD = (
    "On a case card",
    (
        ("case.resolve", ":white_check_mark:", "resolve"),
        ("case.resolve", ":x:", "resolve as not a conduct matter"),
        ("case.act", ":ban:", "log an action"),
    ),
)

SECTIONS = (LOOKUP, NOTES, GUARDS, SLOWMODE, CHANNEL_GUARDS, PURGE, THREAD, CARD)


def line(command, note):
    return f"> `{command}` - {note}"


def section(title, rows, capabilities):
    lines = [line(command, note) for key, command, note in rows if key in capabilities]
    if not lines:
        return None
    return "*{}*\n{}".format(title, "\n".join(lines))


def section_block(title, rows, capabilities):
    text = section(title, rows, capabilities)
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}} if text else None


def grant_prompt(granters):
    if not granters:
        return NO_ACCESS_NO_GRANTERS
    return NO_ACCESS.format(who=", ".join(f"<@{one}>" for one in granters))


def build_blocks(capabilities, granters=()):
    built = [{"type": "section", "text": {"type": "mrkdwn", "text": HEADER}}]
    visible_sections = [section_block(title, rows, capabilities) for title, rows in SECTIONS]
    visible_sections = [one for one in visible_sections if one]

    if not visible_sections:
        return [
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": grant_prompt(granters)},
            }
        ]

    for one in visible_sections:
        built.append({"type": "divider"})
        built.append(one)
    return built


def fallback_text(capabilities):
    parts = [section(title, rows, capabilities) for title, rows in SECTIONS]
    return "\n\n".join(one for one in parts if one) or HEADER


def build_view(capabilities, granters=()):
    return {"text": fallback_text(capabilities), "blocks": build_blocks(capabilities, granters)}
