HELD = "SELECT capability FROM app.effective_capability WHERE user_id = %s"

GRANTERS = """
SELECT user_id FROM app.effective_capability WHERE capability = 'access.grant'
ORDER BY user_id
"""

OPENING = (
    "*Nemo* keeps the Fire Department's cases, and this is all of it from Slack. "
    "Only what you hold is listed."
)

NOTHING = (
    "You hold nothing in the Fire Department yet, so there is nothing here to run. "
    "Ask {who} for a grant."
)

NOBODY = (
    "You hold nothing in the Fire Department yet, so there is nothing here to run. "
    "Ask a community manager for a grant."
)

LOOKING = (
    "Looking things up",
    (
        ("case.read", "/nemo lookup @somebody", "their record: standing, counts, history"),
        ("case.read", "/nemo 3864", "pull that case up here"),
    ),
)

WRITING = (
    "Writing things down",
    (
        ("member.note", "/nemo note @somebody what you found",
         "a standing note that follows them to every case"),
        ("case.open", "/nemo open @somebody what happened", "open a case about them"),
    ),
)

HOLDING = (
    "Holding somebody",
    (
        ("member.guard", "/nemo shush @somebody 3d why",
         "a shush with no case behind it, until that date"),
        ("member.guard", "/nemo channelban @somebody #channel 3d why",
         "a channel ban with no case behind it, until that date"),
    ),
)

THREAD = (
    "In a case thread",
    (
        ("case.reply", "?we are looking at it", "goes to the reporter, with your name on it"),
        ("case.reply", "~?we are looking at it", "goes to the reporter, without your name"),
        ("case.chat", "anything else", "stays with the team as case chat"),
    ),
)

CARD = (
    "On a case card",
    (
        ("case.open", "Take it, Hand it back", "claim a case or put it back"),
        ("case.act", "Log an action", "warning, shush, ban, channel ban, locked thread"),
        ("case.resolve", "Resolve", "close it, and tell the reporter if you want"),
        ("case.reopen", "Reopen", "put a closed case back in the queue"),
        ("case.people", "More · Subject", "say who the case is about"),
        ("case.categorise", "More · Violation", "set what kind of thing it was"),
        ("case.note", "More · Note", "keep a note on the case"),
    ),
)

SECTIONS = (LOOKING, WRITING, HOLDING, THREAD, CARD)


def line(command, note):
    return f"> `{command}` · {note}"


def section(title, rows, held):
    lines = [line(command, note) for key, command, note in rows if key in held]
    if not lines:
        return None
    return "*{}*\n{}".format(title, "\n".join(lines))


def words(title, rows, held):
    text = section(title, rows, held)
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}} if text else None


def grant_prompt(granters):
    if not granters:
        return NOBODY
    return NOTHING.format(who=", ".join(f"<@{one}>" for one in granters))


def build_blocks(held, granters=()):
    built = [{"type": "section", "text": {"type": "mrkdwn", "text": OPENING}}]
    shown = [words(title, rows, held) for title, rows in SECTIONS]
    shown = [one for one in shown if one]

    if not shown:
        return [
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": grant_prompt(granters)},
            }
        ]

    for one in shown:
        built.append({"type": "divider"})
        built.append(one)
    return built


def flat(held):
    parts = [section(title, rows, held) for title, rows in SECTIONS]
    return "\n\n".join(one for one in parts if one) or OPENING


def build_view(held, granters=()):
    return {"text": flat(held), "blocks": build_blocks(held, granters)}
