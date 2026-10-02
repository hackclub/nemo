import datetime as dt
import logging
import time

from slack_sdk.errors import SlackApiError

from bot.core import audit, session
from bot.nemo import activity, channel
from bot.nemo.cards import activity as card
from bot.nemo.surface import on_action, on_shortcut

log = logging.getLogger("bot.nemo")

SHORTCUT = "message_activity"

NOT_A_POST = "That is a reply. Activity is counted on top-level posts only."
NOT_SHOWN = "This channel does not show how posts did."
NOT_YOURS = "That post is not yours."
NOT_NOW = "Slack would not say how that post did just now. Try again in a minute."

NO_FILE = "slack_file"
FILE_SETTLES = 0.8
FILE_TRIES = 3


def filled(client, view_id, shown, plain):
    """Slack takes a moment to make an uploaded chart usable in a block, and
    refuses the whole view until it has. Wait it out, then go without it"""
    for attempt in range(FILE_TRIES):
        last = attempt == FILE_TRIES - 1
        try:
            return client.views_update(view_id=view_id, view=plain if last else shown)
        except SlackApiError as failure:
            if NO_FILE not in str(failure):
                raise
            log.warning("activity: slack would not take the chart yet: %s", failure)
            time.sleep(FILE_SETTLES)
    return None


def is_reply(message):
    root = message.get("thread_ts")
    return bool(root) and root != message.get("ts")


def refused(conn, ctx, why, ts):
    audit.record(
        conn, "permission", 0, "refused", ctx.user_id,
        after={"permission": "message.read", "surface": f"shortcut:{SHORTCUT}",
               "channel_id": ctx.channel_id, "ts": ts},
    )
    return ctx.whisper(why)


@on_shortcut(SHORTCUT, needs="message.read")
def asked(ctx):
    message = ctx.body.get("message") or {}
    ts = message.get("ts")
    if not ts or not ctx.channel_id:
        return ctx.whisper("That is not a message.")
    if is_reply(message):
        return ctx.whisper(NOT_A_POST)

    author_id = message.get("user")
    with session() as conn:
        if not activity.shown(conn, ctx.channel_id):
            return ctx.whisper(NOT_SHOWN)
        if not activity.may_read(ctx.user_id, author_id):
            return refused(conn, ctx, NOT_YOURS, ts)
        found = activity.landed(conn, ctx.channel_id, ts)
        crowd = activity.members(conn, ctx.channel_id)

    opened = ctx.client.views_open(trigger_id=ctx.trigger_id, view=card.reading())
    view_id = ((opened or {}).get("view") or {}).get("id")

    stats = activity.fetch(ctx.channel_id, ts)
    if stats is None:
        shown = plain = card.sorry(NOT_NOW)
    else:
        posted_at = (found or {}).get("posted_at") or dt.datetime.fromtimestamp(float(ts), dt.UTC)
        file_id, span = activity.chart(ctx.client, stats["curves"], posted_at, stats["viewers"])
        said = (ctx.channel_id, ts, author_id, message.get("text"), stats)
        kept = {"found": found, "crowd": crowd,
                "activity_url": channel.app_url(f"/messages/{ctx.channel_id}/{ts}")}
        shown = card.view(*said, chart=(file_id, span) if file_id else None, **kept)
        plain = card.view(*said, **kept)

    if view_id:
        filled(ctx.client, view_id, shown, plain)
    log.info("nemo: %s read how %s/%s did", ctx.user_id, ctx.channel_id, ts)
    return stats


@on_action(card.OPEN_ACTIVITY, open_to_all=True)
def on_open_activity(ctx):
    return None


@on_action(card.OPEN_TOP_REPLY, open_to_all=True)
def on_open_top_reply(ctx):
    return None
