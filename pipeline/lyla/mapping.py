import datetime as dt
import re

LYLA_BOT_USER_ID = "U0852GV4XBQ"

SKIPPED_CASES = frozenset({3646})
SKIPPED_ACTIONS = frozenset({225, 480, 529, 638, 674, 794, 969, 1556})

CATEGORY_KEYS = {
    0: "nos",
    1: "adult",
    2: "insulting",
    3: "bullying",
    4: "discrimination",
    5: "hateful",
    6: "harassment_identity",
    7: "harassment_general",
    8: "nsfw_mild",
    9: "nsfw_extreme",
    10: "advertising",
    11: "spam",
    12: "fraud_hcb",
    13: "fraud_referral",
    14: "fraud_ysws",
    15: "fraud_other",
    16: "ban_evasion",
    17: "unwanted_dms",
    18: "private_info",
    19: "impersonation",
    20: "disruption",
    21: "bot_misuse",
}
CATEGORY_CODES = {key: code for code, key in CATEGORY_KEYS.items()}
NEMO_NAMED_CODES = frozenset({11, 17, 18, 19, 20, 21})

LABELS = {
    "warning": "Warning",
    "dm": "DM",
    "shush": "Shush",
    "temp_ban": "Temp Ban",
    "indef_ban": "Indef Ban",
    "perma_ban": "Perma Ban",
    "channel_ban": "Channel Ban",
    "locked_thread": "Locked Thread",
    "deleted_messages": "Deleted messages",
}
TYPES = {label: key for key, label in LABELS.items()}
TYPE_ORDER = list(LABELS)
REVERSED_PREFIX = "Reversed: "
SEPARATOR = ", "

EXPIRING_TYPES = frozenset({"shush", "temp_ban", "channel_ban"})
ENDING_TYPES = EXPIRING_TYPES | {"indef_ban", "perma_ban"}

OPEN = "open"
RESOLVED = "resolved"
CANCELED = "canceled"
MERGED = "merged"
EXPIRED = "expired"

ACTION_TAKEN = "action_taken"
NO_ACTION = "no_action"
NOT_CONDUCT = "not_conduct"
DUPLICATE = "duplicate"

DURATION = (r"\d+\s*(?:-|\s)?\s*(?:h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks|mo|mon|mnth"
            r"|month|months|y|yr|yrs|year|years)\b")
CONDITIONAL = re.compile(
    r"\b(next|future|would|may|probably|discussing|if another|if they|considered)\b.*", re.I)
OFF_SLACK = re.compile(
    r"(?:(?:perma\w*|indef\w*|temp)\s+)?(ysws|mc server|minecraft|fallout|event|mcg|hcb|clubs)\s*ban"
    r"|ban(ned)? from (mc|minecraft|slack/clubs|clubs)|made mcg|into mcg", re.I)
BOTS = re.compile(r"\b(bot|app)\b", re.I)
CHANNEL_BAN = re.compile(
    r"channel\s*-?\s*ban|\bcban|chanel ban|channel removal|channelshush"
    r"|remov(?:ed|al) from (?:#|the |channel|meta|\w+ for)")
NOT_PLAIN_BAN = re.compile(r"channel\s*-?\s*ban|\bcban|chanel ban|perma|indef|unban")
PERMALINK = re.compile(r"archives/([A-Z0-9]+)/p(\d{10})(\d{6})")
PERMALINK_THREAD = re.compile(r"thread_ts=(\d+\.\d+)")
MENTION = re.compile(r"[<@>\s]")


def classify(text, has_end):
    words = OFF_SLACK.sub("", CONDITIONAL.sub("", (text or "").lower()))
    found = set()
    if CHANNEL_BAN.search(words):
        found.add("channel_ban")
    if re.search(r"perma|permanent", words) and "channel ban" not in words:
        found.add("perma_ban")
    if re.search(r"\bindef", words):
        found.add("indef_ban")
    if ("shush" in words and "channelshush" not in words
            and "remainder of original shush" not in words):
        found.add("shush")
    if re.search(r"\block", words):
        found.add("locked_thread")
    if re.search(r"\bwarn|reminder|\bremind", words):
        found.add("warning")
    if re.search(r"\bdm|\bdms\b|direct message|reached out", words):
        found.add("dm")
    if re.search(r"delet|destroy", words):
        found.add("deleted_messages")
    if re.search(r"deactivat|\bdeac\b", words) and not BOTS.search(words):
        found.add("temp_ban" if has_end else "indef_ban")
    plain_ban = re.search(r"\bban(?:ned)?\b", words) and not NOT_PLAIN_BAN.search(words)
    if plain_ban or "temp ban" in words:
        timed = has_end or re.search(DURATION, words) or "temp" in words
        found.add("temp_ban" if timed else "indef_ban")
    if "perma_ban" in found:
        found -= {"indef_ban", "temp_ban"}
    return [key for key in TYPE_ORDER if key in found]


def parse_action_type(text, has_end):
    text = (text or "").strip()
    known, rest = [], []
    for part in text.split(SEPARATOR):
        part = part.strip()
        if part in TYPES:
            known.append((TYPES[part], False))
        elif part.startswith(REVERSED_PREFIX) and part[len(REVERSED_PREFIX):] in TYPES:
            known.append((TYPES[part[len(REVERSED_PREFIX):]], True))
        elif part:
            rest.append(part)
    if known:
        return unique(known), SEPARATOR.join(rest) or None
    return [(key, False) for key in classify(text, has_end)], text or None


def unique(types):
    seen, kept = set(), []
    for key, reversed_ in types:
        if key in seen:
            continue
        seen.add(key)
        kept.append((key, reversed_))
    return kept


def compose_action_type(types, solution=None):
    parts = [f"{REVERSED_PREFIX if reversed_ else ''}{LABELS[key]}" for key, reversed_ in types]
    if solution:
        parts.append(solution)
    return SEPARATOR.join(parts)


def lyla_status(resolved_at, resolution):
    if resolved_at is None:
        return OPEN
    if resolution == NOT_CONDUCT:
        return CANCELED
    if resolution == DUPLICATE:
        return MERGED
    return RESOLVED


def resolution_for(status, has_live_actions):
    if status == CANCELED:
        return NOT_CONDUCT
    if status == MERGED:
        return DUPLICATE
    if status == RESOLVED:
        return ACTION_TAKEN if has_live_actions else NO_ACTION
    return None


def from_ms(value):
    if value is None:
        return None
    return dt.datetime.fromtimestamp(int(value) / 1000, tz=dt.UTC)


def to_ms(value):
    if value is None:
        return None
    return int(value.timestamp() * 1000)


def ended_at(expires_at, reversed_at):
    ends = [one for one in (expires_at, reversed_at) if one is not None]
    return min(ends) if ends else None


def ban_until(expires_at):
    return expires_at.astimezone(dt.UTC).date().isoformat() if expires_at else None


def expiry_from(value):
    if not value:
        return None
    try:
        day = dt.date.fromisoformat(str(value)[:10])
    except ValueError:
        return None
    return dt.datetime(day.year, day.month, day.day, tzinfo=dt.UTC)


def same_day(expires_at, value):
    return ban_until(expires_at) == (str(value)[:10] if value else None)


def thread_of(permalink):
    match = PERMALINK.search(permalink or "")
    if not match:
        return None
    channel_id, seconds, micros = match.groups()
    thread = PERMALINK_THREAD.search(permalink)
    return channel_id, thread.group(1) if thread else f"{seconds}.{micros}"


def user_id(value):
    cleaned = MENTION.sub("", value or "")
    return cleaned or None


def thread_key(channel_id, ts):
    return f"{channel_id}:{ts}"
