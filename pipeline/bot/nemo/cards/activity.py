"""The modal behind "view message activity": one post, its numbers, a way to the chart"""

TITLE = "View message activity"
OPEN_ACTIVITY = "open_message_activity"
OPEN_TOP_REPLY = "open_top_reply"

TITLES = {
    "1h": "the first hour",
    "1d": "the first day",
    "1w": "the first week",
    "30d": "the first month",
}

QUOTE_LIMIT = 280
ARCHIVES = "https://hackclub.slack.com/archives"


def n(value):
    return f"{int(value):,}"


def quoted(text):
    said = " ".join((text or "").split())
    if not said:
        return "_(no text)_"
    if len(said) > QUOTE_LIMIT:
        said = said[: QUOTE_LIMIT - 1].rstrip() + "…"
    return "\n".join(f"> {line}" for line in said.splitlines()) or f"> {said}"


def posted_line(author_id, channel_id, ts):
    when = int(float(ts))
    stamp = f"<!date^{when}^{{date_short}} at {{time}}|{when}>"
    who = f"<@{author_id}>" if author_id else "somebody"
    return f"{who} · {stamp} · <#{channel_id}>"


def crowd_line(viewers, crowd):
    if not crowd:
        return ""
    share = round(100 * viewers / crowd)
    return f" · {share}% of the channel"


def replies_line(found):
    if found is None:
        return "not landed yet"
    count = found.get("reply_count") or 0
    people = found.get("reply_users_count") or 0
    if not count:
        return "none"
    return f"{n(count)} from {n(people)} {'person' if people == 1 else 'people'}"


def clients_line(clients):
    said = [f"{share}% {label}" for label, count, share in clients if share is not None and count]
    return " · ".join(said) if said else "no viewer breakdown yet"


def first_line(curves):
    hour = sum(count for _, count in curves.get("1h") or [])
    day = sum(count for _, count in curves.get("1d") or [])
    if not hour and not day:
        return None
    return f"{n(hour)} viewers in the first hour, {n(day)} in the first day"


def reply_url(channel_id, root_ts, reply_ts):
    return (
        f"{ARCHIVES}/{channel_id}/p{reply_ts.replace('.', '')}"
        f"?thread_ts={root_ts}&cid={channel_id}"
    )


def chart_block(file_id, span):
    return {
        "type": "image",
        "slack_file": {"id": file_id},
        "alt_text": f"new viewers over {TITLES.get(span, span)}, minute by minute",
    }


def view(channel_id, ts, author_id, text, stats, found=None, crowd=None,
         chart=None, activity_url=None):
    fields = [
        f"*Viewers*\n{n(stats['viewers'])}{crowd_line(stats['viewers'], crowd)}",
        f"*Reacted*\n{n(stats['reacted'])}",
        f"*Clicked a link*\n{n(stats['clicked'])}",
        f"*Shared*\n{n(stats['shared'])}",
        f"*Replies*\n{replies_line(found)}",
    ]
    blocks = [
        {"type": "section", "text": {"type": "mrkdwn", "text": quoted(text)}},
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": posted_line(author_id, channel_id, ts)}],
        },
        {"type": "divider"},
        {
            "type": "section",
            "fields": [{"type": "mrkdwn", "text": one} for one in fields],
        },
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": clients_line(stats["clients"])}],
        },
    ]

    if chart:
        blocks.append(chart_block(*chart))

    first = first_line(stats["curves"])
    if first:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": first}]})

    buttons = []
    if activity_url:
        buttons.append(
            {
                "type": "button",
                "action_id": OPEN_ACTIVITY,
                "text": {"type": "plain_text", "text": "Open activity"},
                "url": activity_url,
                "style": "primary",
            }
        )
    if stats.get("top_reply_ts"):
        buttons.append(
            {
                "type": "button",
                "action_id": OPEN_TOP_REPLY,
                "text": {"type": "plain_text", "text": "Top reply"},
                "url": reply_url(channel_id, ts, stats["top_reply_ts"]),
            }
        )
    if buttons:
        blocks.append({"type": "actions", "elements": buttons})

    return {
        "type": "modal",
        "title": {"type": "plain_text", "text": TITLE},
        "close": {"type": "plain_text", "text": "Close"},
        "blocks": blocks,
    }


def reading():
    return {
        "type": "modal",
        "title": {"type": "plain_text", "text": TITLE},
        "close": {"type": "plain_text", "text": "Close"},
        "blocks": [
            {"type": "section", "text": {"type": "mrkdwn", "text": "Asking Slack how it did…"}}
        ],
    }


def sorry(said):
    return {
        "type": "modal",
        "title": {"type": "plain_text", "text": TITLE},
        "close": {"type": "plain_text", "text": "Close"},
        "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": said}}],
    }
