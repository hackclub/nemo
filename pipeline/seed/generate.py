import bisect
import json
import math
import random
from dataclasses import dataclass, field
from datetime import date, timedelta

from seed import SEED_CHANNEL_PREFIX, SEED_USER_PREFIX
from seed.profile import PROFILE_FILE

COVERED_DAYS = 400
CHANNELS_PER_MEMBER = 0.06
HOME_CHANNELS = (1, 6)
MAX_TAIL_ALPHA = 6.0
LIFETIME_MIN_DAYS = 3.0
LIFETIME_SCALE_DAYS = 300.0
LIFETIME_EXPONENT = 2.5

WORDS = (
    "lounge welcome ship code design hardware music games photos books coffee garden rocket "
    "pixels synth bakery lantern harbor meadow atlas beacon cider dunes ember fjord glacier "
    "hollow indigo juniper kelp lumen marsh nimbus orchard prairie quartz ripple summit tundra "
    "umbra violet willow xenon yarrow zephyr build learn share help ask show tell make"
).split()

PREFIXES = ("", "hack-", "club-", "team-", "the-", "ask-", "show-")
SUFFIXES = ("", "-help", "-chat", "-dev", "-hq", "-lab", "-club", "-2026")


class Sampler:
    def __init__(self, block):
        self.p = list(block.get("p") or [])
        self.v = list(block.get("v") or [])

    def __call__(self, u):
        if not self.v:
            return 0.0
        if u <= self.p[0]:
            return self.v[0]
        if u >= self.p[-1]:
            return self._tail(u)
        i = bisect.bisect_right(self.p, u) - 1
        span = self.p[i + 1] - self.p[i]
        t = 0.0 if span <= 0 else (u - self.p[i]) / span
        return self.v[i] + t * (self.v[i + 1] - self.v[i])

    def zero_crossing(self):
        for p, v in zip(self.p, self.v, strict=True):
            if v > 0:
                return p
        return 1.0

    def _tail(self, u):
        top, prev = self.v[-1], self.v[-2] if len(self.v) > 1 else 0.0
        if top <= 0 or prev <= 0 or u >= 1.0:
            return top
        ratio = math.log((1 - self.p[-2]) / (1 - self.p[-1]))
        alpha = math.log(top / prev) / ratio if ratio > 0 and top > prev else 1.0
        alpha = min(max(alpha, 0.1), MAX_TAIL_ALPHA)
        return top * ((1 - self.p[-1]) / (1 - u)) ** alpha


@dataclass
class Member:
    user_id: str
    cohort_at: date
    engagement: float
    claimed_at: date | None
    invite_pending: bool
    is_bot: bool
    is_admin: bool
    is_restricted: bool
    is_ultra_restricted: bool
    deactivated_at: date | None
    total_messages: int
    first_post_at: date | None
    first_post_channel: str | None
    home_channels: list = field(default_factory=list)


@dataclass
class Channel:
    channel_id: str
    name: str
    visibility: str
    archived: bool
    date_created: date
    total_members: int
    guests: int


@dataclass
class Event:
    user_id: str
    channel_id: str
    day: date
    messages: int
    reactions: int


def load_profile(path=PROFILE_FILE):
    return json.loads(path.read_text())


def clip(value, low=0.0, high=1.0):
    return min(max(value, low), high)


def jitter(rng, value, spread=0.12):
    return clip(value + rng.gauss(0, spread))


def cohort_calendar(profile, members, as_of):
    sizes = profile["members"]["cohort_sizes"]
    total = sum(count for _, count in sizes) or 1
    last = date.fromisoformat(sizes[-1][0])
    shift = (as_of.year - last.year) * 12 + (as_of.month - last.month)
    calendar = []
    for iso, count in sizes:
        month = date.fromisoformat(iso)
        moved = shift_months(month, shift)
        calendar.append((moved, round(count * members / total)))
    return [(month, count) for month, count in calendar if count > 0 and month <= as_of]


def shift_months(day, months):
    index = (day.year * 12 + day.month - 1) + months
    return date(index // 12, index % 12 + 1, 1)


def make_channels(rng, profile, count, as_of):
    members_q = Sampler(profile["channels"]["total_members"])
    guest_q = Sampler(profile["channels"]["guest_share"])
    archived_rate = profile["channels"]["archived_rate"]
    channels, seen = [], set()
    for i in range(count):
        name = unique_name(rng, seen)
        total = max(1, int(members_q(rng.random())))
        guests = int(total * clip(guest_q(rng.random())))
        channels.append(
            Channel(
                channel_id=f"{SEED_CHANNEL_PREFIX}{i:07d}",
                name=name,
                visibility="public",
                archived=rng.random() < archived_rate,
                date_created=as_of - timedelta(days=rng.randint(30, COVERED_DAYS * 4)),
                total_members=total,
                guests=guests,
            )
        )
    return channels


def unique_name(rng, seen):
    for _ in range(50):
        name = f"{rng.choice(PREFIXES)}{rng.choice(WORDS)}{rng.choice(SUFFIXES)}"
        if rng.random() < 0.25:
            name = f"{name}-{rng.choice(WORDS)}"
        if name not in seen:
            seen.add(name)
            return name
    name = f"{rng.choice(WORDS)}-{len(seen)}"
    seen.add(name)
    return name


def make_members(rng, profile, count, channels, as_of):
    rates = profile["members"]["rates"]
    messages_q = Sampler(profile["messaging"]["total_messages"])
    delay_q = Sampler(profile["messaging"]["join_to_first_post_hours"])
    weights = channel_weights(channels)
    members, index = [], 0
    for month, size in cohort_calendar(profile, count, as_of):
        for _ in range(size):
            members.append(
                make_member(rng, rates, messages_q, delay_q, channels, weights, month, index, as_of)
            )
            index += 1
    return members


def make_member(rng, rates, messages_q, delay_q, channels, weights, month, index, as_of):
    days_in = min(27, (as_of - month).days) if month <= as_of else 0
    cohort_at = month + timedelta(days=rng.randint(0, max(0, days_in)))
    engagement = rng.random()
    is_bot = rng.random() < rates["is_bot"]
    total = 0 if is_bot else int(messages_q(jitter(rng, engagement, 0.05)))

    first_post_at, first_post_channel, home = None, None, []
    if total > 0:
        home = pick_channels(rng, channels, weights, rng.randint(*HOME_CHANNELS))
        delay = max(0.0, delay_q(rng.random()))
        first_post_at = cohort_at + timedelta(hours=delay)
        if first_post_at > as_of:
            first_post_at, total = None, 0
        else:
            first_post_channel = home[0].channel_id

    deactivated_at = None
    if rng.random() < rates["is_deleted"]:
        span = max(1, (as_of - cohort_at).days)
        deactivated_at = cohort_at + timedelta(days=rng.randint(1, span))

    return Member(
        user_id=f"{SEED_USER_PREFIX}{index:07d}",
        cohort_at=cohort_at,
        engagement=engagement,
        claimed_at=cohort_at if rng.random() < rates["claimed"] else None,
        invite_pending=rng.random() < rates["invite_pending"],
        is_bot=is_bot,
        is_admin=rng.random() < rates["is_admin"],
        is_restricted=rng.random() < rates["is_restricted"],
        is_ultra_restricted=rng.random() < rates["is_ultra_restricted"],
        deactivated_at=deactivated_at,
        total_messages=total,
        first_post_at=first_post_at.date() if hasattr(first_post_at, "date") else first_post_at,
        first_post_channel=first_post_channel,
        home_channels=home,
    )


def channel_weights(channels):
    running, total = [], 0
    for channel in channels:
        total += channel.total_members
        running.append(total)
    return running


def pick_channels(rng, channels, weights, count):
    picked, seen = [], set()
    for _ in range(count * 3):
        if len(picked) >= count:
            break
        i = bisect.bisect_left(weights, rng.random() * weights[-1])
        i = min(i, len(channels) - 1)
        if i not in seen:
            seen.add(i)
            picked.append(channels[i])
    return picked or [channels[0]]


def seasonal_factor(profile, day):
    dow = {int(k): v for k, v in profile["seasonality"]["day_of_week"]}
    month = {int(k): v for k, v in profile["seasonality"]["month_of_year"]}
    return dow.get((day.weekday() + 1) % 7, 1.0) * month.get(day.month, 1.0)


def seasonal_table(profile, start, days):
    return [seasonal_factor(profile, start + timedelta(days=i)) for i in range(days)]


def poster_rank(engagement, floor):
    if floor >= 1.0:
        return 0.0
    return clip((engagement - floor) / (1 - floor))


def lifetime_days(rng, rank):
    mean = LIFETIME_MIN_DAYS + LIFETIME_SCALE_DAYS * rank**LIFETIME_EXPONENT
    return max(1.0, rng.expovariate(1 / mean))


def member_events(rng, member, sim, start, days):
    if not member.first_post_at or not member.home_channels:
        return
    rank = poster_rank(member.engagement, sim["floor"])
    churn = member.first_post_at + timedelta(days=lifetime_days(rng, rank))
    if member.deactivated_at:
        churn = min(churn, member.deactivated_at)

    begin = max(start, member.first_post_at)
    last = min(start + timedelta(days=days - 1), churn)
    if last < begin:
        return

    rate = clip(sim["rate_q"](jitter(rng, member.engagement, 0.15)), 0.01, 0.95)
    sticky = sim["sticky"]
    active = True
    for i in range((begin - start).days, (last - start).days + 1):
        day = start + timedelta(days=i)
        daily = clip(rate * sim["table"][i], 0.005, 0.95)
        threshold = sticky if active else daily * (1 - sticky) / max(1e-6, 1 - daily)
        active = rng.random() < clip(threshold, 0.005, 0.98)
        if not active:
            continue
        channel = member.home_channels[rng.randrange(len(member.home_channels))]
        yield Event(
            member.user_id,
            channel.channel_id,
            day,
            max(1, int(sim["msg_q"](jitter(rng, member.engagement, 0.2)))),
            max(0, int(sim["react_q"](rng.random()))),
        )


def simulation(profile, start, days):
    active_q = Sampler(profile["activity"]["active_days_per_member"])
    covered = max(1, profile["activity"]["covered_days"])
    messages_q = Sampler(profile["messaging"]["total_messages"])
    return {
        "table": seasonal_table(profile, start, days),
        "rate_q": lambda u: active_q(u) / covered,
        "msg_q": Sampler(profile["activity"]["messages_per_active_day"]),
        "react_q": Sampler(profile["activity"]["reactions_per_active_day"]),
        "sticky": profile["activity"]["stay_active_next_day"],
        "floor": messages_q.zero_crossing(),
    }


def events(rng, members, profile, as_of, days=COVERED_DAYS):
    start = as_of - timedelta(days=days - 1)
    sim = simulation(profile, start, days)
    for member in members:
        yield from member_events(rng, member, sim, start, days)


def build(scale_members, seed=1, as_of=None, profile=None):
    profile = profile or load_profile()
    as_of = as_of or date.today()
    rng = random.Random(seed)
    channels = make_channels(
        rng, profile, max(20, round(scale_members * CHANNELS_PER_MEMBER)), as_of
    )
    members = make_members(rng, profile, scale_members, channels, as_of)
    return channels, members, profile, as_of, rng
