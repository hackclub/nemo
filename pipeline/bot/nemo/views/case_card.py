import hashlib
import json

from bot.core.formatting import short_end
from bot.nemo import categories
from bot.nemo.views import action, lengths, resolve

LOG_ACTION = "case_log_action"
MORE = "case_more"
CLAIM = "case_claim"
RESOLVE = "case_resolve"
REOPEN = "case_reopen"
REOPEN_AFTER_REPLY = "case_reopen_after_reply"

OPEN = "open"
RESOLVED = "resolved"
MERGED = "merged"

TITLE_LIMIT = 150
BODY_LIMIT = 200
SUBTEXT_LIMIT = 200
PEOPLE_LIMIT = 3
ACTIONS_LIMIT = 100


def state(case):
    if not case.get("resolved_at"):
        return OPEN
    return MERGED if case.get("resolution") == "duplicate" else RESOLVED


def people(user_ids):
    labels = [f"<@{one}>" for one in user_ids[:PEOPLE_LIMIT]]
    hidden = len(user_ids) - len(labels)
    if hidden:
        labels.append(f"{hidden} more")
    if len(labels) < 2:
        return "".join(labels)
    return ", ".join(labels[:-1]) + f" and {labels[-1]}"


def capitalized(text):
    return text[:1].upper() + text[1:]


def join(parts):
    text = ", ".join(part for part in parts if part)
    return text if text.startswith("<") else capitalized(text)


def case_link(case_id, url):
    return f"<{url}|case {case_id}>" if url else f"case {case_id}"


def by_user(user_id):
    return f" by <@{user_id}>" if user_id else ""


def status_clause(case):
    kind = state(case)
    if kind == MERGED:
        target = case_link(case.get("duplicate_of"), case.get("duplicate_url")) if case.get("duplicate_of") else "another case"
        return f"merged into {target}{by_user(case.get('resolved_by'))}"
    if kind == RESOLVED:
        return f"resolved{by_user(case.get('resolved_by'))}"
    assignees = case.get("assignees") or []
    return f"assigned to {people(assignees)}" if assignees else "unassigned"


def body_text(case):
    subjects = case.get("subjects") or []
    return join([people(subjects), status_clause(case)])[:BODY_LIMIT]


def action_summary(case):
    counts = {}
    for key in case.get("actions") or []:
        counts[key] = counts.get(key, 0) + 1
    labels = [action.label(key) + (f" ({count})" if count > 1 else "") for key, count in counts.items()]
    return ", ".join(labels)[:ACTIONS_LIMIT]


def updated_phrase(case):
    at = case.get("updated_at")
    if not at:
        return ""
    return f"updated <!date^{int(at.timestamp())}^{{ago}}|{short_end(at)}>"


def subtext(case):
    kind = state(case)
    head = None
    if kind in (RESOLVED, MERGED) and case.get("resolution"):
        head = resolve.label(case["resolution"])
    return join([head, action_summary(case), updated_phrase(case)])[:SUBTEXT_LIMIT]


def title(case):
    return f"Case {case['case_id']}, {state(case)}"[:TITLE_LIMIT]


def subtitle(case):
    key = case.get("category_key")
    return categories.label(key) if key else None


def button(action_id, text, case_id, style=None, confirm=None):
    built = {"type": "button", "action_id": action_id, "text": lengths.plain(text), "value": str(case_id)}
    if style:
        built["style"] = style
    if confirm:
        built["confirm"] = confirm
    return built


def reopen_confirm(case_id):
    return {
        "title": lengths.plain("Reopen case"),
        "text": {"type": "mrkdwn", "text": f"Reopen case {case_id}."},
        "confirm": lengths.plain("Reopen"),
        "deny": lengths.plain("Cancel"),
    }


def reopen_prompt_blocks(case_id, text):
    return [
        {"type": "section", "text": {"type": "mrkdwn", "text": text}},
        {"type": "actions", "elements": [button(REOPEN_AFTER_REPLY, "Reopen Case", case_id, "primary")]},
    ]


def buttons(case):
    case_id = case["case_id"]
    kind = state(case)
    more = button(MORE, "More", case_id)
    if kind == MERGED:
        return [more]
    if kind == RESOLVED:
        return [more, button(REOPEN, "Reopen", case_id, "primary", reopen_confirm(case_id))]
    log = button(LOG_ACTION, "Log action", case_id)
    if case.get("assignees"):
        return [log, more, button(RESOLVE, "Resolve", case_id, "primary")]
    return [log, more, button(CLAIM, "Claim", case_id, "primary")]


def card_block(case):
    built = {"type": "card", "title": lengths.plain(title(case))}
    if case.get("subject_icon"):
        built["icon"] = {"type": "image", "image_url": case["subject_icon"], "alt_text": "Subject"}
    head = subtitle(case)
    if head:
        built["subtitle"] = lengths.plain(head)
    built["body"] = {"type": "mrkdwn", "text": body_text(case)}
    tail = subtext(case)
    if tail:
        built["subtext"] = {"type": "mrkdwn", "text": tail}
    built["actions"] = buttons(case)
    return built


def blocks(case):
    return [card_block(case)]


def fallback(case):
    head = subtitle(case)
    return f"{title(case)}, {head}" if head else title(case)


def render(case):
    return {"text": fallback(case), "blocks": blocks(case)}


def digest(case):
    payload = json.dumps(render(case), sort_keys=True, default=str)
    return hashlib.sha256(payload.encode()).hexdigest()
