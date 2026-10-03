"""Message activity for a top-level post, from Slack's message activity API."""

import datetime as dt
import logging

from bot.core import privileged
from bot.nemo import plot
from lib.proxy_client import ProxyError

log = logging.getLogger("bot.nemo")

METHOD = "insights.messageStats"

SHOWN = """
SELECT 1 FROM app.channel_message_activity WHERE channel_id = %s
"""

LANDED = """
SELECT reply_count, reply_users_count, posted_at
FROM archive.message
WHERE channel_id = %s AND ts = %s
"""

MEMBERS = """
SELECT total_members
FROM raw.channel_activity_snapshot
WHERE channel_id = %s AND source = 'admin_analytics_channel_range'
ORDER BY window_end DESC
LIMIT 1
"""

SPANS = ("1h", "1d", "1w", "30d")
CLIENTS = (("browser_count", "browser"), ("desktop_count", "desktop"), ("mobile_count", "mobile"))


def shown(conn, channel_id):
    return conn.execute(SHOWN, (channel_id,)).fetchone() is not None


def landed(conn, channel_id, ts):
    row = conn.execute(LANDED, (channel_id, ts)).fetchone()
    if row is None:
        return None
    return {"reply_count": row[0], "reply_users_count": row[1], "posted_at": row[2]}


def members(conn, channel_id):
    row = conn.execute(MEMBERS, (channel_id,)).fetchone()
    return row[0] if row else None


def may_read(user_id, author_id):
    """True when the requester is the message author and Slack reports an author."""
    return bool(author_id) and author_id == user_id


def chart(client, curves, posted_at, viewers):
    """Render the span appropriate to the post's age and upload the PNG privately.
    Returns the file id for an image block, or None when either step fails."""
    age = (dt.datetime.now(dt.UTC) - posted_at).total_seconds() if posted_at else 0
    span = plot.span_for(age)
    png = plot.render(curves.get(span) or [], span, viewers=viewers, age_seconds=age)
    if png is None:
        return None, span
    try:
        sent = client.files_upload_v2(
            content=png, filename=f"activity-{span}.png",
            title=f"Viewers over {plot.TITLES[span]}",
        )
    except Exception as failure:  # noqa: BLE001
        log.warning("activity: could not hand the chart to slack: %s", failure)
        return None, span
    files = (sent.get("files") if isinstance(sent, dict) else getattr(sent, "data", {}).get("files")) or []
    file_id = files[0].get("id") if files else None
    return file_id, span


def fetch(channel_id, ts):
    try:
        found = privileged.proxy().call(
            METHOD, {"channel": channel_id, "ts": ts}, credential="internal", max_retries=1
        )
    except ProxyError as failure:
        log.warning("activity: could not read %s/%s: %s", channel_id, ts, failure)
        return None
    return shaped((found or {}).get("stats") or {})


def share(count, whole):
    if not whole:
        return None
    return round(100 * count / whole)


def clients(stats):
    breakdown = stats.get("client_breakdown") or {}
    counts = [(label, int(breakdown.get(key) or 0)) for key, label in CLIENTS]
    whole = sum(count for _, count in counts)
    return [(label, count, share(count, whole)) for label, count in counts]


def curve(stats, span):
    """Return (timestamp, unique_viewers) pairs per bucket for the given span."""
    series = (stats.get("viewers_time_series") or {}).get("data") or []
    for one in series:
        if one.get("seriesType") != span:
            continue
        return [
            (dt.datetime.fromtimestamp(int(point["value"]) / 1_000_000, dt.UTC), int(point.get("count") or 0))
            for point in one.get("series") or []
            if point.get("value") is not None
        ]
    return []


def shaped(stats):
    return {
        "viewers": int(stats.get("num_users_viewed") or 0),
        "reacted": int(stats.get("num_users_reacted") or 0),
        "clicked": int(stats.get("num_users_clicked") or 0),
        "shared": int(stats.get("num_shares") or 0),
        "clients": clients(stats),
        "top_reply_ts": stats.get("top_threaded_reply_by_reactions_ts"),
        "curves": {span: curve(stats, span) for span in SPANS},
    }
