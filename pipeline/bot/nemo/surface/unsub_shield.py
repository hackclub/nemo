import logging

from bot.nemo import guardwork, responses
from bot.nemo.carriers import carrying
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

SAID = "UNSUBSCRIBE"

TOLD = (
    "To stop notifications for a thread, use 'Turn off notifications for replies' "
    "on the thread instead."
)

WITH_LINK = "{said} <{link}|See how>"


def asked_to_stop(event):
    return (event.get("text") or "").strip().upper() == SAID


@on_event("message", open_to_all=True)
def seen(ctx):
    event = ctx.payload or {}
    if not responses.shielding():
        return None

    channel_id, subject_id, ts = carrying.ours(event)
    if not channel_id or not event.get("thread_ts") or not asked_to_stop(event):
        return None

    try:
        guardwork.remove(ctx.client, channel_id, ts)
    except Exception as failure:
        log.info("nemo: could not take down the unsubscribe in %s: %s", channel_id, failure)
        return None

    link = responses.said(responses.UNSUB_SHIELD_LINK)
    carrying.whisper(ctx.client, channel_id, subject_id,
                     WITH_LINK.format(said=TOLD, link=link) if link else TOLD)
    log.info("nemo: took down an unsubscribe from %s in %s", subject_id, channel_id)
    return True
