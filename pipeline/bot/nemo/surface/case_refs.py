import logging
import re

from bot.core import session
from bot.nemo import channel, chat, thread_commands
from bot.nemo.surface import on_event
from bot.nemo.views import case_refs as view

log = logging.getLogger("bot.nemo")

LIMIT = 10
CHAT_SUBTYPES = (None, "file_share", "me_message", "thread_broadcast")
CASE_REF = re.compile(r"(?<![\w#&/])#(\d{3,6})(?!\w)")
CODE = re.compile(r"```.*?```|`[^`\n]*`", re.DOTALL)
SLACK_TOKEN = re.compile(r"<[^<>\n]*>")

CASES = "SELECT id, duplicate_of FROM fd.cases WHERE id = ANY(%s)"
VISIBILITY = "SELECT visibility FROM raw.channel_dim WHERE channel_id = %s"
PUBLIC = "public"


def numbers(text):
    plain = SLACK_TOKEN.sub(" ", CODE.sub(" ", text or ""))
    found = []
    for match in CASE_REF.finditer(plain):
        number = int(match.group(1))
        if number not in found:
            found.append(number)
    return found[:LIMIT]


def fd_channels():
    return (channel.case_channels() | {channel.log_channel()}) - {None}


def is_public(conn, channel_id):
    row = conn.execute(VISIBILITY, (channel_id,)).fetchone()
    return bool(row) and row[0] == PUBLIC


def linked_cases(conn, case_ids):
    if not case_ids:
        return [], []
    found = dict(conn.execute(CASES, (list(case_ids),)).fetchall())
    shown = [case_id for case_id in case_ids if case_id in found]
    lines = [view.line(case_id, found[case_id], channel.case_url, lambda one: channel.thread_url(conn, one))
             for case_id in shown]
    return shown, lines


@on_event("message", open_to_all=True)
def link_case_refs(ctx):
    event = ctx.payload or {}
    if event.get("bot_id") or event.get("subtype") not in CHAT_SUBTYPES:
        return None
    channel_id = event.get("channel")
    if channel_id not in fd_channels():
        return None
    wanted = numbers(event.get("text"))
    if not wanted:
        return None
    ts = event.get("ts")
    thread_ts = event.get("thread_ts") or ts
    in_thread = thread_ts != ts
    if in_thread and thread_commands.parse_command(event.get("text"))[0]:
        return None

    with session() as conn:
        if is_public(conn, channel_id):
            return None
        own_case = chat.case_of_thread(conn, thread_ts) if in_thread else None
        shown, lines = linked_cases(conn, [case_id for case_id in wanted if case_id != own_case])
    if not lines:
        return None

    try:
        ctx.client.chat_postMessage(channel=channel_id, thread_ts=thread_ts, unfurl_links=False,
                                    unfurl_media=False, **view.message(shown, lines))
    except Exception as failure:
        log.warning("nemo: could not link cases %s in %s: %s", shown, channel_id, failure)
        return None
    return shown
