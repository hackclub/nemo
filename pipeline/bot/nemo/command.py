import logging
import re

from bot.engine import access, audit, richtext, session
from bot.nemo import channel, record
from bot.nemo.cards import help as helping
from bot.nemo.cards import report

log = logging.getLogger("bot.nemo")

COMMAND = "/nemo"
LOOKUP = "lookup"
NOTE = "note"
OPEN = "open"
OPEN_RECORD = "open_record"

ABOUT_SOMEBODY = (LOOKUP, NOTE, OPEN)
NEEDS_WORDS = (NOTE, OPEN)

WHO = re.compile(r"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>")
CASE = re.compile(r"\A#?(\d+)\Z")
MEMBER_ID = re.compile(r"\A[UW][A-Z0-9]{2,}\Z")

ASK_FOR_SOMEBODY = {
    LOOKUP: "Name somebody: */nemo lookup @them*",
    NOTE: "Name somebody: */nemo note @them what you found*",
    OPEN: "Name somebody: */nemo open @them what happened*",
}

ASK_FOR_WORDS = {
    NOTE: "Say what you found: */nemo note @them what you found*",
    OPEN: "Say what happened: */nemo open @them what happened*",
}


def asked(text):
    said = (text or "").strip()
    if not said:
        return None, None, None

    first, _, rest = said.partition(" ")
    number = CASE.match(first)
    if number:
        return "case", int(number.group(1)), None

    verb = first.lower()
    if verb not in ABOUT_SOMEBODY:
        return None, None, None

    found = WHO.search(rest)
    if not found:
        return verb, None, None

    who = found.group(1)
    body = re.sub(r"\s+", " ", rest[: found.start()] + " " + rest[found.end() :]).strip()
    return verb, (who if MEMBER_ID.match(who) else None), body or None


def said_only(text):
    return {
        "text": text,
        "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": text}}],
    }


def bullets(entries):
    return {
        "type": "rich_text",
        "elements": [
            {
                "type": "rich_text_list",
                "style": "bullet",
                "elements": [
                    {"type": "rich_text_section", "elements": richtext.elements(record.line(one))}
                    for one in entries
                ],
            }
        ],
    }


def looked_up(found, names=None):
    user_id = found["user_id"]
    blocks = [
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*<@{user_id}>*  ·  {record.standing_line(found['in_force'])}"},
        },
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": record.counted(found["counts"])}],
        },
    ]

    if found["entries"]:
        blocks.append({"type": "divider"})
        blocks.append(bullets(found["entries"]))
        if found["total"] > len(found["entries"]):
            blocks.append(
                {
                    "type": "context",
                    "elements": [
                        {
                            "type": "mrkdwn",
                            "text": f"showing {len(found['entries'])} of {found['total']}",
                        }
                    ],
                }
            )
    else:
        blocks.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": "Nothing on their record at all."}],
            }
        )

    where = channel.member_url(user_id)
    if where:
        blocks.append(
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "action_id": OPEN_RECORD,
                        "text": {"type": "plain_text", "text": "Their whole record"},
                        "url": where,
                    }
                ],
            }
        )

    return {"text": f"the record of {user_id}", "blocks": blocks}


NEEDED = {
    LOOKUP: "case.read",
    NOTE: "member.note",
    OPEN: "case.open",
    "case": "case.read",
}


def already_open(user_id, numbers):
    said = ", ".join(f"*case {one}*" for one in numbers)
    return (
        f"<@{user_id}> already has an open case, {said}. "
        "Add what you found to that one instead."
    )


def opened(case_id, user_id, noted):
    said = f"*case {case_id}* opened about <@{user_id}>"
    return said if noted else f"{said}, with nothing written on it yet"


def helped(user_id):
    with session() as conn:
        held = {row[0] for row in conn.execute(helping.HELD, (user_id,)).fetchall()}
        granters = (
            [row[0] for row in conn.execute(helping.GRANTERS).fetchall()] if not held else []
        )
    return helping.view(held, granters)


def register(app):
    @app.action(OPEN_RECORD)
    def on_open_record(ack):
        ack()

    @app.command(COMMAND)
    def on_nemo(ack, command, respond):
        ack()
        verb, wanted, body = asked(command.get("text"))
        user_id = command["user_id"]

        if verb is None:
            return respond(**helped(user_id))
        if verb in ABOUT_SOMEBODY and wanted is None:
            return respond(**said_only(ASK_FOR_SOMEBODY[verb]))
        if verb in NEEDS_WORDS and not body:
            return respond(**said_only(ASK_FOR_WORDS[verb]))

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, NEEDED[verb])
            if not allowed:
                return respond(**said_only(refusal))

            if verb == LOOKUP:
                answer = looked_up(record.read(conn, wanted))
                audit.record(conn, "member", 0, "looked_up", user_id,
                             after={"user_id": wanted})
            elif verb == NOTE:
                channel.member_note(conn, wanted, body, user_id)
                answer = said_only(
                    f"noted about <@{wanted}>, and it follows them to every case"
                )
            elif verb == OPEN:
                held = channel.open_about(conn, wanted)
                if held:
                    answer = said_only(already_open(wanted, held))
                else:
                    case_id = channel.open_case(conn, wanted, body, user_id)
                    answer = said_only(opened(case_id, wanted, body))
            else:
                case = channel.gather(conn, wanted)
                answer = (
                    {"text": f"case {wanted}", "blocks": report.blocks(case)}
                    if case
                    else said_only(f"There is no case {wanted}.")
                )

        log.info("nemo: %s ran %s on %s", user_id, verb, wanted)
        return respond(**answer)
