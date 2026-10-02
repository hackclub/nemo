import datetime as dt
import logging
import re

from bot.core import access, audit, richtext, session
from bot.nemo import casework, channel, memberguards, record
from bot.nemo.cards import help as helping
from bot.nemo.cards import report

log = logging.getLogger("bot.nemo")

COMMAND = "/nemo"
LOOKUP = "lookup"
NOTE = "note"
OPEN = "open"
SHUSH = "shush"
CHANNEL_BAN = "channelban"
OPEN_RECORD = "open_record"

ABOUT_SOMEBODY = (LOOKUP, NOTE, OPEN, SHUSH, CHANNEL_BAN)
NEEDS_WORDS = (NOTE, OPEN, SHUSH, CHANNEL_BAN)

WHO = re.compile(r"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>")
WHERE = re.compile(r"<#(C[A-Z0-9]+)(?:\|[^>]*)?>")
CASE = re.compile(r"\A#?(\d+)\Z")
MEMBER_ID = re.compile(r"\A[UW][A-Z0-9]{2,}\Z")
FOR_A_WHILE = re.compile(r"\A(\d{1,3})([dw])\Z", re.IGNORECASE)
ON_A_DATE = re.compile(r"\A(\d{4})-(\d{2})-(\d{2})\Z")

LONGEST_DAYS = 365

ASK_FOR_SOMEBODY = {
    LOOKUP: "Name somebody: */nemo lookup @them*",
    NOTE: "Name somebody: */nemo note @them what you found*",
    OPEN: "Name somebody: */nemo open @them what happened*",
    SHUSH: "Name somebody: */nemo shush @them 3d why*",
    CHANNEL_BAN: "Name somebody: */nemo channelban @them #channel 3d why*",
}

ASK_FOR_WORDS = {
    NOTE: "Say what you found: */nemo note @them what you found*",
    OPEN: "Say what happened: */nemo open @them what happened*",
    SHUSH: "Say how long and why: */nemo shush @them 3d why*",
    CHANNEL_BAN: "Say how long and why: */nemo channelban @them #channel 3d why*",
}

HOW_LONG = (
    "Say how long it runs first: *{said}*. "
    f"Days or weeks, up to {LONGEST_DAYS} days, or a date like 2026-10-15."
)

ASK_FOR_TIME = {
    SHUSH: HOW_LONG.format(said="/nemo shush @them 3d why"),
    CHANNEL_BAN: HOW_LONG.format(said="/nemo channelban @them #channel 3d why"),
}

ASK_FOR_CHANNEL = "Name the channel: */nemo channelban @them #channel 3d why*"


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


def ends_on(said):
    found = FOR_A_WHILE.match(said)
    if found:
        days = int(found.group(1)) * (7 if found.group(2).lower() == "w" else 1)
        if not 1 <= days <= LONGEST_DAYS:
            return None
        return dt.date.today() + dt.timedelta(days=days)

    found = ON_A_DATE.match(said)
    if not found:
        return None

    try:
        on = dt.date(int(found.group(1)), int(found.group(2)), int(found.group(3)))
    except ValueError:
        return None
    return on if on > dt.date.today() else None


def for_how_long(body):
    first, _, rest = (body or "").partition(" ")
    on = ends_on(first)
    if on is None:
        return None, None
    return on, re.sub(r"\s+", " ", rest).strip() or None


def in_a_channel(body):
    found = WHERE.search(body or "")
    if not found:
        return None, None

    said = body[: found.start()] + " " + body[found.end() :]
    return found.group(1), re.sub(r"\s+", " ", said).strip() or None


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
    SHUSH: "member.guard",
    CHANNEL_BAN: "member.guard",
    "case": "case.read",
}


def already_open(user_id, numbers):
    said = ", ".join(f"*case {one}*" for one in numbers)
    return (
        f"<@{user_id}> already has an open case, {said}. "
        "Add what you found to that one instead."
    )


def shushed(user_id, on):
    return (
        f"shush held on <@{user_id}> until {on.strftime('%-d %b')}, on no case. "
        "Log it on a case if there is one."
    )


def already_shushed(user_id):
    return (
        f"<@{user_id}> is already under a shush. "
        "Lift it or run it longer in Fire Engine."
    )


def banned(user_id, channel_id, on):
    return (
        f"channel ban held on <@{user_id}> in <#{channel_id}> "
        f"until {on.strftime('%-d %b')}, on no case. "
        "Log it on a case if there is one."
    )


def already_banned(user_id, channel_id):
    return (
        f"<@{user_id}> is already banned from <#{channel_id}>. "
        "Lift it or run it longer in Fire Engine."
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
                casework.member_note(conn, wanted, body, user_id)
                answer = said_only(
                    f"noted about <@{wanted}>, and it follows them to every case"
                )
            elif verb == SHUSH:
                on, why = for_how_long(body)
                if on is None:
                    answer = said_only(ASK_FOR_TIME[SHUSH])
                elif not why:
                    answer = said_only(ASK_FOR_WORDS[SHUSH])
                else:
                    guard_id = memberguards.open_guard(
                        conn, memberguards.SHUSH, wanted, user_id, why,
                        expires_at=f"{on} 23:59:59",
                    )
                    answer = said_only(
                        shushed(wanted, on) if guard_id else already_shushed(wanted)
                    )
            elif verb == CHANNEL_BAN:
                where, rest = in_a_channel(body)
                on, why = for_how_long(rest)
                if where is None:
                    answer = said_only(ASK_FOR_CHANNEL)
                elif on is None:
                    answer = said_only(ASK_FOR_TIME[CHANNEL_BAN])
                elif not why:
                    answer = said_only(ASK_FOR_WORDS[CHANNEL_BAN])
                else:
                    guard_id = memberguards.open_guard(
                        conn, memberguards.CHANNEL_BAN, wanted, user_id, why,
                        channel_id=where, expires_at=f"{on} 23:59:59",
                    )
                    answer = said_only(
                        banned(wanted, where, on) if guard_id
                        else already_banned(wanted, where)
                    )
            elif verb == OPEN:
                held = casework.open_about(conn, wanted)
                if held:
                    answer = said_only(already_open(wanted, held))
                else:
                    case_id = casework.open_case(conn, wanted, body, user_id)
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
