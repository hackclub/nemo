import logging
from concurrent.futures import ThreadPoolExecutor

from bot.core import privileged
from bot.core.formatting import short_end_token
from bot.nemo import channel
from bot.nemo.views import case_view, member_view
from bot.nemo.views.activity import message_url
from lib.proxy_client import InternalApiError, InternalAuthError, ProxyError

log = logging.getLogger("bot.nemo")

SHOWN = 10
MAX_COUNT = 100
FETCH = MAX_COUNT + 1
TEXT_LIMIT = 400
WORKERS = 5
FAILURES = (ProxyError, InternalApiError, InternalAuthError)

MENTIONS = "SELECT channel_id, ts, thread_root_ts, posted_at, author_id FROM fd.member_mentions(%s, NULL, %s)"


def read(conn, user_id, limit=FETCH):
    rows = conn.execute(MENTIONS, (user_id, limit)).fetchall()
    return [
        {"channel_id": row[0], "ts": row[1], "thread_root_ts": row[2], "posted_at": row[3], "author_id": row[4]}
        for row in rows
    ]


def is_reply(row):
    return bool(row["thread_root_ts"]) and row["thread_root_ts"] != row["ts"]


def message_text(row):
    try:
        if is_reply(row):
            response = privileged.replies(
                row["channel_id"], row["thread_root_ts"], limit=2, oldest=row["ts"], latest=row["ts"])
        else:
            response = privileged.history(row["channel_id"], limit=1, oldest=row["ts"], latest=row["ts"])
    except FAILURES as failure:
        log.warning("mentions: %s %s not fetched: %s", row["channel_id"], row["ts"], failure)
        return None
    found = next((one for one in response.get("messages") or [] if one.get("ts") == row["ts"]), None)
    return (found or {}).get("text") or None


def with_text(rows, fetch=message_text):
    shown = rows[:SHOWN]
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        texts = list(pool.map(fetch, shown))
    return [{**row, "text": text} for row, text in zip(shown, texts)] + rows[SHOWN:]


def count_text(total):
    if total > MAX_COUNT:
        return f"{MAX_COUNT}+ mentions"
    return f"{total} {'mention' if total == 1 else 'mentions'}"


def line(row):
    author = f"<@{row['author_id']}>" if row["author_id"] else "Unknown"
    url = message_url(row["channel_id"], row["ts"], row["thread_root_ts"])
    kind = ", thread reply" if is_reply(row) else ""
    return f"<#{row['channel_id']}>  {author}  {short_end_token(row['posted_at'])}{kind}  <{url}|Open>"


def entry(row):
    quote = case_view.quoted(row.get("text"), TEXT_LIMIT)
    return f"{line(row)}\n{quote}" if quote else line(row)


def web_url(user_id):
    url = channel.member_url(user_id)
    return f"{url}?tab=mentions" if url else None


def build_reply(user_id, rows):
    if not rows:
        text = "No mentions"
        return {"text": text, "blocks": [case_view.section(text)]}

    head = f"*<@{user_id}>*  {count_text(len(rows))}"
    blocks = [case_view.section(head)]
    for one in rows[:SHOWN]:
        blocks.append({"type": "divider"})
        blocks.append(case_view.section(entry(one)))
    url = web_url(user_id)
    if url:
        blocks.append({
            "type": "actions",
            "elements": [member_view.button(member_view.OPEN_WEB, "Show in Nemo", url=url)],
        })
    return {"text": head, "blocks": blocks}
