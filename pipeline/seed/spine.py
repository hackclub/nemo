import collections
import math
from datetime import datetime, time, timedelta, timezone

from ingest.channel_history_pull import SOURCE, SUBSTANTIVE_CHARS, TRANSPORT

EVENT_TRANSPORT = "events"

REPLY_SHARE = 0.18
MENTION_SHARE = 0.22
QUESTION_SHARE = 0.15
LINK_SHARE = 0.08
EMOJI_ONLY_SHARE = 0.06
BOT_SHARE = 0.03
FILE_SHARE = 0.05
EDITED_SHARE = 0.04

LENGTH_MU = math.log(21)
LENGTH_SIGMA = 1.1
LENGTH_CAP = 4000

ROOT_MEMORY = 40
REPLY_WINDOW_SECONDS = 48 * 3600
EVENT_TRANSPORT_DAYS = 7

DAY_START_HOUR = 6
DAY_SPAN_SECONDS = 16 * 3600

MESSAGE_COLUMNS = [
    "channel_id", "ts", "source", "author_id", "author_kind", "subtype", "thread_root_ts",
    "is_reply", "posted_at", "edited_at", "edited_by", "reply_count", "reply_users_count",
    "latest_reply_ts", "reaction_count", "reactor_count", "file_count", "text_length",
    "mention_count", "is_question", "is_substantive", "has_link", "emoji_only",
    "mentioned_ids", "observed_at",
]

THREAD_COLUMNS = [
    "channel_id", "root_ts", "reply_count", "reply_users_count", "latest_reply_ts",
    "replies_fetched", "fetched_through_ts", "fetched_at", "seen_at",
]

WALK_COLUMNS = [
    "channel_id", "oldest_ts", "newest_ts", "messages_seen", "history_complete",
    "last_walked_at", "updated_at",
]

OBSERVATION_COLUMNS = ["channel_id", "ts", "transport", "observed_at"]


class Message:
    __slots__ = (
        "channel_id", "ts", "at", "author_id", "is_bot", "root_ts", "is_reply",
        "reactions", "repliers", "reply_count", "latest_reply_ts", "mentioned",
    )

    def __init__(self, channel_id, ts, at, author_id, is_bot, reactions):
        self.channel_id = channel_id
        self.ts = ts
        self.at = at
        self.author_id = author_id
        self.is_bot = is_bot
        self.reactions = reactions
        self.root_ts = None
        self.is_reply = False
        self.repliers = set()
        self.reply_count = 0
        self.latest_reply_ts = None
        self.mentioned = []


def stamp(at):
    return f"{at.timestamp():.6f}"


def day_seconds(rng):
    return DAY_START_HOUR * 3600 + rng.random() * DAY_SPAN_SECONDS


def spread(rng, day, count):
    base = datetime.combine(day, time(0, 0), tzinfo=timezone.utc)
    return sorted(base + timedelta(seconds=day_seconds(rng)) for _ in range(count))


def text_length(rng):
    return min(LENGTH_CAP, max(1, round(rng.lognormvariate(LENGTH_MU, LENGTH_SIGMA))))


def by_channel_day(events):
    held = collections.defaultdict(list)
    for event in events:
        if event.messages > 0:
            held[event.channel_id].append(event)
    return held


def channel_messages(rng, channel_id, events, bots):
    made = []
    for event in events:
        at_list = spread(rng, event.day, event.messages)
        share = event.reactions / event.messages if event.messages else 0
        for at in at_list:
            reactions = int(share) + (1 if rng.random() < share - int(share) else 0)
            made.append(
                Message(channel_id, stamp(at), at, event.user_id,
                        event.user_id in bots, reactions)
            )
    made.sort(key=lambda m: m.ts)
    return made


def thread_them(rng, made):
    recent = collections.deque(maxlen=ROOT_MEMORY)
    for message in made:
        candidates = [
            root for root in recent
            if root.author_id != message.author_id
            and (message.at - root.at).total_seconds() <= REPLY_WINDOW_SECONDS
        ]
        if candidates and rng.random() < REPLY_SHARE:
            root = candidates[-1]
            message.is_reply = True
            message.root_ts = root.ts
            root.repliers.add(message.author_id)
            root.reply_count += 1
            root.latest_reply_ts = message.ts
            root.root_ts = root.ts
            if rng.random() < MENTION_SHARE:
                message.mentioned = [root.author_id]
            continue
        recent.append(message)
        if candidates and rng.random() < MENTION_SHARE:
            message.mentioned = [candidates[-1].author_id]
    return made


def message_row(rng, message, as_of):
    length = text_length(rng)
    edited = rng.random() < EDITED_SHARE
    return (
        message.channel_id,
        message.ts,
        SOURCE,
        message.author_id,
        "bot" if message.is_bot else "member",
        None,
        message.root_ts,
        message.is_reply,
        message.at,
        message.at + timedelta(minutes=2) if edited else None,
        message.author_id if edited else None,
        message.reply_count or None,
        len(message.repliers) or None,
        message.latest_reply_ts,
        message.reactions,
        message.reactions,
        1 if rng.random() < FILE_SHARE else 0,
        length,
        len(message.mentioned),
        rng.random() < QUESTION_SHARE,
        length >= SUBSTANTIVE_CHARS,
        rng.random() < LINK_SHARE,
        rng.random() < EMOJI_ONLY_SHARE,
        message.mentioned,
        as_of,
    )


def thread_rows(made, as_of):
    for message in made:
        if message.reply_count:
            yield (
                message.channel_id,
                message.ts,
                message.reply_count,
                len(message.repliers),
                message.latest_reply_ts,
                message.reply_count,
                message.latest_reply_ts,
                as_of,
                as_of,
            )


def walk_row(channel_id, made, as_of):
    return (
        channel_id,
        made[0].ts,
        made[-1].ts,
        len(made),
        True,
        as_of,
        as_of,
    )


def observation_rows(made, cutoff, as_of):
    for message in made:
        yield (message.channel_id, message.ts, TRANSPORT, as_of)
        if message.at >= cutoff:
            yield (message.channel_id, message.ts, EVENT_TRANSPORT, as_of)


def build(rng, events, members, as_of):
    bots = {member.user_id for member in members if member.is_bot}
    stamped = datetime.combine(as_of, time(12, 0), tzinfo=timezone.utc)
    cutoff = stamped - timedelta(days=EVENT_TRANSPORT_DAYS)
    held = by_channel_day(events)
    messages, threads, walks, observations = [], [], [], []
    for channel_id in sorted(held):
        made = thread_them(rng, channel_messages(rng, channel_id, held[channel_id], bots))
        if not made:
            continue
        messages.extend(message_row(rng, message, stamped) for message in made)
        threads.extend(thread_rows(made, stamped))
        walks.append(walk_row(channel_id, made, stamped))
        observations.extend(observation_rows(made, cutoff, stamped))
    return messages, threads, walks, observations
