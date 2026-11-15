import datetime as dt

from bot.core.formatting import escape, escape_but_member_tokens, outside_token, short_end
from bot.nemo.views import action, case_card, lengths
from bot.nemo.views.activity import message_url

CALLBACK = "case_view"

ANONYMOUS = "Anonymous"
UNASSIGNED = "Unassigned"
TRUNCATED = "..."

BODY_LIMIT = case_card.BODY_LIMIT
ASSIGNEES_SHOWN = 10
ACTIONS_SHOWN = 6
NOTES_SHOWN = 5
THREADS_SHOWN = 5
REASON_LIMIT = 200
NOTE_LIMIT = 500


def epoch(at):
    return int(at.timestamp())


def ago(at):
    return f"<!date^{epoch(at)}^{{ago}}|{short_end(at)}>"


def section(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def context(text):
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": text}]}


def header(text):
    return {"type": "header", "text": lengths.plain(text)}


def shorten(text, size):
    if len(text) <= size:
        return text
    return text[: outside_token(text, size)].rstrip() + TRUNCATED


def quoted(body, limit=BODY_LIMIT):
    text = " ".join((body or "").split())
    if not text:
        return None
    size = len(text)
    while True:
        rendered = f"> {escape_but_member_tokens(shorten(text, size))}"
        if len(rendered) <= limit or size <= 1:
            return rendered[:limit]
        size = max(1, min(size - 1, size - (len(rendered) - limit)))


def assignee_line(assignees):
    if not assignees:
        return UNASSIGNED
    shown = [f"<@{one}>" for one in assignees[:ASSIGNEES_SHOWN]]
    hidden = len(assignees) - len(shown)
    if hidden:
        shown.append(f"{hidden} more")
    return f"Assignees: {', '.join(shown)}"


def title_text(case, reporter):
    if reporter["anonymous"]:
        return ANONYMOUS
    if reporter["user_id"]:
        return f"<@{reporter['user_id']}>"
    return f"Case {case['case_id']}"


def card_block(case, reporter):
    built = {"type": "card", "title": {"type": "mrkdwn", "text": title_text(case, reporter)}}
    if reporter.get("icon"):
        built["icon"] = {"type": "image", "image_url": reporter["icon"], "alt_text": "Reporter"}
    body = quoted(case.get("body"))
    if body:
        built["body"] = {"type": "mrkdwn", "text": body}
    built["actions"] = case_card.buttons(case)
    return built


def action_text(entry):
    head = f"*{escape(action.label(entry['type_key']))}*  <@{entry['target_user_id']}>"
    if entry.get("channel_id"):
        head += f" in <#{entry['channel_id']}>"
    if entry.get("expires_at"):
        head += f", ends {escape(short_end(entry['expires_at']))}"
    lines = [head]
    if entry.get("reason"):
        lines.append(escape(shorten(entry["reason"], REASON_LIMIT)))
    lines.append(f"_<@{entry['performed_by']}>, {ago(entry['performed_at'])}_")
    return "\n".join(lines)


def note_text(note):
    return f"*<@{note['author']}>*  _{ago(note['created_at'])}_\n{escape(shorten(note['body'], NOTE_LIMIT))}"


def thread_text(thread):
    link = message_url(thread["channel_id"], thread["thread_ts"])
    posted = dt.datetime.fromtimestamp(float(thread["thread_ts"]), tz=dt.UTC)
    return f"<#{thread['channel_id']}>  <{link}|Open thread>\n_{ago(posted)}_"


def listing(title, items, render, shown, url):
    if not items:
        return []
    visible = items[-shown:]
    blocks = [header(title), section("\n\n".join(render(one) for one in visible))]
    hidden = len(items) - len(visible)
    if hidden:
        label = f"{hidden} more"
        blocks.append(context(f"<{url}|{label} in Fire Engine>" if url else label))
    return blocks


def footer(thread_url, url):
    links = []
    if thread_url:
        links.append(f"<{thread_url}|Open thread>")
    if url:
        links.append(f"<{url}|Open in Fire Engine>")
    return [context("   ".join(links))] if links else []


def build_view(case, reporter, entries, notes, thread_url=None, notice=None, threads=()):
    url = case.get("url")
    blocks = []
    if notice:
        blocks.append(context(notice))
    blocks.append(context(assignee_line(case.get("assignees") or [])))
    blocks.append(card_block(case, reporter))
    blocks += listing("Actions", entries, action_text, ACTIONS_SHOWN, url)
    blocks += listing("Notes", notes, note_text, NOTES_SHOWN, url)
    blocks += listing("Slack threads", list(threads), thread_text, THREADS_SHOWN,
                      f"{url}?tab=threads" if url else None)
    blocks += footer(thread_url, url)
    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case["case_id"]),
        "title": lengths.plain(f"Case {case['case_id']}"),
        "close": lengths.plain("Close"),
        "blocks": blocks,
    }
