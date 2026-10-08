import datetime as dt
import logging

from bot.core import session
from bot.core.formatting import escape
from bot.nemo import channel, channelguards

log = logging.getLogger("bot.nemo")

IDLE_TIMEOUT = dt.timedelta(hours=1)
MAX_AGE = dt.timedelta(hours=24)
GIVE_UP_AFTER = 3
GROUPS_PER_DRAIN = 50
EVENTS_PER_CLAIM = 100
MARKETPLACE = "https://hackclub.slack.com/marketplace"
QUOTE_LIMIT = 1200
CUT = "\n[truncated]"


def naming(subject_id, label):
    if subject_id.startswith("U"):
        return f"<@{subject_id}>"
    return f"*{label or subject_id}*"


def quoted(words):
    text = (words or "").strip()
    if not text:
        return ""
    if len(text) > QUOTE_LIMIT:
        text = text[:QUOTE_LIMIT].rstrip() + CUT
    return "\n" + "\n".join(f"> {line}" for line in escape(text).splitlines())


def marketplace_url(app_id):
    return f"{MARKETPLACE}/{app_id}" if app_id else None


def footer(channel_id, link=None, app_id=None):
    shown = (
        (link, "message link"),
        (marketplace_url(app_id), "marketplace"),
        (channel.channel_url(channel_id), "open in fire engine"),
    )
    parts = [f"<{url}|{name}>" for url, name in shown if url]
    return "\n" + "  ·  ".join(parts) if parts else ""


def plural(count, one, many):
    return f"{count} {one if count == 1 else many}"


def summary(name, channel_id, deleted, kicked):
    parts = [f"{name} is not on the allow list for <#{channel_id}>."]
    if deleted:
        parts.append(f"Deleted {plural(deleted, 'message', 'messages')}.")
    if kicked:
        parts.append(f"Removed from the channel {plural(kicked, 'time', 'times')}.")
    return " ".join(parts)


def detail_of(event):
    name = naming(event["subject_id"], event["label"])
    room = event["channel_id"]
    if event["verb"] == "deleted":
        return (f"Deleted a message from {name}, which is not on the allow list for <#{room}>."
                + quoted(event["message_text"]) + footer(room, event["permalink"], event["app_id"]))
    if event["verb"] == "kicked":
        return (f"Put {name} out of <#{room}>, which is not on its allow list."
                + footer(room, app_id=event["app_id"]))
    if event["message_ts"]:
        return (f":warning: Could not delete a message from {name} in <#{room}> "
                f"({event['detail']})."
                + quoted(event["message_text"]) + footer(room, event["permalink"], event["app_id"]))
    return (f":warning: {name} joined <#{room}> off the allow list, and we could not put "
            f"them out ({event['detail']})." + footer(room, app_id=event["app_id"]))


def counts(events):
    return (sum(1 for one in events if one["verb"] == "deleted"),
            sum(1 for one in events if one["verb"] == "kicked"))


def failed(conn, events):
    for event_id, attempts in channelguards.notice_failed(conn, [one["id"] for one in events]):
        if attempts >= GIVE_UP_AFTER:
            log.warning("nemo: gave up on the notice for guard event %s after %s attempts",
                        event_id, attempts)


def post(client, conn, guard_id, subject_id, events):
    first = events[0]
    name = naming(subject_id, first["label"])
    room = first["channel_id"]
    log_channel = channel.internal_log_channel(conn)
    thread = channelguards.open_notice_thread(conn, guard_id, subject_id, IDLE_TIMEOUT, MAX_AGE)
    planned = counts(events)

    fresh = thread is None
    if fresh:
        try:
            sent = client.chat_postMessage(channel=log_channel, text=summary(name, room, *planned),
                                           unfurl_links=False)
        except Exception as failure:
            log.warning("nemo: could not open a notice thread for guard %s: %s", guard_id, failure)
            failed(conn, events)
            return False
        parent_ts = sent.get("ts")
        thread_id = channelguards.open_new_notice_thread(conn, guard_id, subject_id, parent_ts, 0, 0)
    else:
        thread_id, parent_ts = thread

    done = []
    for event in events:
        try:
            client.chat_postMessage(channel=log_channel, text=detail_of(event),
                                    thread_ts=parent_ts, unfurl_links=False)
        except Exception as failure:
            log.warning("nemo: could not reply in notice thread %s: %s", parent_ts, failure)
            break
        done.append(event)

    totals = channelguards.note_event(conn, thread_id, *counts(done))
    if done:
        channelguards.noticed(conn, [one["id"] for one in done])
    left = events[len(done):]
    if left:
        failed(conn, left)

    if not (fresh and totals == planned):
        try:
            client.chat_update(channel=log_channel, ts=parent_ts,
                               text=summary(name, room, *totals))
        except Exception as failure:
            log.warning("nemo: could not update notice thread %s: %s", parent_ts, failure)

    return not left


def drain_group(client, guard_id, subject_id):
    while True:
        with session() as conn:
            events = channelguards.claim_notices(conn, guard_id, subject_id,
                                                 GIVE_UP_AFTER, EVENTS_PER_CLAIM)
            if not events:
                return
            if not post(client, conn, guard_id, subject_id, events):
                return
        if len(events) < EVENTS_PER_CLAIM:
            return


def drain(client):
    with session() as conn:
        groups = channelguards.notice_groups(conn, GIVE_UP_AFTER, GROUPS_PER_DRAIN)

    for guard_id, subject_id in groups:
        try:
            drain_group(client, guard_id, subject_id)
        except Exception:
            log.exception("nemo: notices for guard %s and %s failed", guard_id, subject_id)

    return len(groups) == GROUPS_PER_DRAIN
