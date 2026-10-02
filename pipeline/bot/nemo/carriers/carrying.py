import logging

from bot.core import privileged
from bot.nemo import memberguards

log = logging.getLogger("bot.nemo")

SPAM = 10
WINDOW = "1 hour"

UNTIL = "until {when}"
ENDLESS = "with no end date"

CARRIES = (None, "file_share", "thread_broadcast", "me_message")


def ending(guard):
    at = guard.get("expires_at")
    return UNTIL.format(when=at.strftime("%-d %b")) if at else ENDLESS


def tell_them(client, conn, guard, said):
    try:
        client.chat_postMessage(channel=guard["subject_id"], text=said)
        detail = None
    except Exception as failure:
        detail = f"could not tell them: {str(failure)[:200]}"
        log.warning("nemo: guard %s is held but %s was not told: %s",
                    guard["id"], guard["subject_id"], failure)

    memberguards.happened(conn, guard["id"], guard["subject_id"], None, "told", detail=detail)


def whisper(client, channel_id, subject_id, said):
    try:
        client.chat_postEphemeral(channel=channel_id, user=subject_id, text=said)
    except Exception as failure:
        log.info("nemo: could not say why %s was stopped in %s: %s",
                 subject_id, channel_id, failure)


def earned_a_reset(conn, guard, verb):
    if memberguards.lately(conn, guard["id"], verb, WINDOW) < SPAM:
        return False
    return memberguards.lately(conn, guard["id"], "reset", WINDOW) == 0


def reset(conn, guard, why):
    how = privileged.reset_sessions(guard["subject_id"])
    memberguards.happened(conn, guard["id"], guard["subject_id"], None, "reset", detail=how)
    log.warning("nemo: %s kept %s through guard %s, sessions %s",
                guard["subject_id"], why, guard["id"], how)
    return how


def ours(event):
    if event.get("subtype") not in CARRIES or event.get("bot_id"):
        return None, None, None

    channel_id = event.get("channel")
    subject_id = event.get("user")
    ts = event.get("ts")
    if not channel_id or not subject_id or not ts:
        return None, None, None
    if channel_id.startswith("D"):
        return None, None, None
    return channel_id, subject_id, ts
