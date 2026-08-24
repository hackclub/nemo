import logging
import re

from bot.engine import access, richtext, session
from bot.nemo import channel, record
from bot.nemo.cards import report

log = logging.getLogger("bot.nemo")

COMMAND = "/nemo"
LOOKUP = "lookup"

WHO = re.compile(r"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>")
CASE = re.compile(r"\A#?(\d+)\Z")

HELP = (
    "*/nemo lookup @somebody* for their whole record, "
    "or */nemo 3864* for a case."
)


def asked(text):
    said = (text or "").strip()
    if not said:
        return None, None

    first, _, rest = said.partition(" ")
    number = CASE.match(first)
    if number:
        return "case", int(number.group(1))

    if first.lower() != LOOKUP:
        return None, None

    found = WHO.search(rest)
    return (LOOKUP, found.group(1)) if found else (LOOKUP, None)


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
                        "action_id": "open_record",
                        "text": {"type": "plain_text", "text": "Their whole record"},
                        "url": where,
                    }
                ],
            }
        )

    return {"text": f"the record of {user_id}", "blocks": blocks}


def register(app):
    @app.command(COMMAND)
    def on_nemo(ack, command, respond):
        ack()
        verb, wanted = asked(command.get("text"))
        user_id = command["user_id"]

        if verb is None:
            return respond(**said_only(HELP))

        if verb == LOOKUP and wanted is None:
            return respond(**said_only("Name somebody: */nemo lookup @them*"))

        with session() as conn:
            key = "identity.read" if verb == LOOKUP else "case.read"
            allowed, refusal = access.may(conn, user_id, key)
            if not allowed:
                return respond(**said_only(refusal))

            if verb == LOOKUP:
                answer = looked_up(record.read(conn, wanted))
            else:
                case = channel.gather(conn, wanted)
                answer = (
                    {"text": f"case {wanted}", "blocks": report.blocks(case)}
                    if case
                    else said_only(f"There is no case {wanted}.")
                )

        log.info("nemo: %s asked for %s %s", user_id, verb, wanted)
        return respond(**answer)
