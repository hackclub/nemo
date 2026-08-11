import collections
import json
import random
from dataclasses import dataclass, field
from datetime import datetime, time, timedelta, timezone

from seed import SEED_REF_PREFIX

CASE_RATE = 0.025
ENGAGEMENT_WEIGHT = 0.7
FIREFIGHTER_COUNT = 5
NO_SUBJECT_SHARE = 0.02
CLAIMED_SHARE = 0.8
SECOND_CASE_SHARE = 0.18
THIRD_CASE_SHARE = 0.05
MEAN_RESOLVE_DAYS = 8.0
MAX_RESOLVE_DAYS = 120.0
CLAIM_FRACTION = 0.3
SECOND_THREAD_SHARE = 0.15
SIBLING_SHARE = 0.08
WITNESS_SHARE = 0.45
SECOND_WITNESS_SHARE = 0.15
REPORTER_IS_TARGET_SHARE = 0.5
REPORTER_IS_WITNESS_SHARE = 0.25
THREAD_LEAD_MINUTES = (2, 240)

RESOLUTION_WEIGHTS = (
    ("action_taken", 0.55),
    ("no_action", 0.28),
    ("duplicate", 0.11),
    ("not_conduct", 0.06),
)

CASE_COLUMNS = [
    "subject_user_id",
    "opened_by",
    "opened_at",
    "claimed_by",
    "claimed_at",
    "resolved_at",
    "resolution",
    "member_note",
    "subject_context",
    "source_app",
    "external_ref",
    "created_at",
    "updated_at",
]

THREAD_COLUMNS = ["case_id", "channel_id", "thread_ts", "is_primary", "added_by"]
PARTICIPANT_COLUMNS = ["case_id", "user_id", "role"]


@dataclass
class SeedCase:
    external_ref: str
    subject_user_id: str | None
    opened_by: str
    opened_at: datetime
    context: dict
    claimed_by: str | None = None
    claimed_at: datetime | None = None
    resolved_at: datetime | None = None
    resolution: str | None = None
    member_note: str | None = None
    threads: list = field(default_factory=list)
    participants: list = field(default_factory=list)


def rng_for(seed):
    return random.Random(f"{seed}:conduct")


def firefighters(members, count=FIREFIGHTER_COUNT):
    ranked = sorted(
        (m for m in members if not m.is_bot),
        key=lambda m: (-m.engagement, m.user_id),
    )
    return [m.user_id for m in ranked[:count]]


def channel_roster(members):
    roster = collections.defaultdict(list)
    for member in members:
        for channel in member.home_channels:
            roster[channel.channel_id].append(member.user_id)
    return roster


def subject_weight(member):
    return ENGAGEMENT_WEIGHT * member.engagement + (1.0 - ENGAGEMENT_WEIGHT)


def eligible(members):
    return [m for m in members if not m.is_bot and m.first_post_at]


def pick_subjects(rng, members, rate=CASE_RATE):
    return [m for m in eligible(members) if rng.random() < rate * subject_weight(m)]


def case_count(rng):
    roll = rng.random()
    if roll < THIRD_CASE_SHARE:
        return 3
    if roll < SECOND_CASE_SHARE:
        return 2
    return 1


def pick_resolution(rng):
    roll = rng.random()
    cumulative = 0.0
    for name, share in RESOLUTION_WEIGHTS:
        cumulative += share
        if roll < cumulative:
            return name
    return RESOLUTION_WEIGHTS[-1][0]


def moment(rng, day):
    return datetime.combine(
        day, time(rng.randrange(24), rng.randrange(60)), tzinfo=timezone.utc
    )


def open_days(rng, member, as_of, count):
    start = member.first_post_at or member.cohort_at
    end = member.deactivated_at or as_of
    span = max((end - start).days, 1)
    offsets = sorted(rng.randrange(span) for _ in range(count))
    return [start + timedelta(days=offset) for offset in offsets]


def slack_ts(rng, at):
    before = at - timedelta(minutes=rng.uniform(*THREAD_LEAD_MINUTES))
    return f"{int(before.timestamp())}.{rng.randrange(1000000):06d}"


def context_for(member, priors, at):
    return {
        "tenure_days": max((at.date() - member.cohort_at).days, 0),
        "total_messages": member.total_messages,
        "channels": len(member.home_channels),
        "priors": priors,
        "captured_at": at.isoformat(),
    }


def pick_other(rng, roster, channel_id, exclude):
    candidates = roster.get(channel_id, ())
    for _ in range(8):
        if not candidates:
            return None
        pick = rng.choice(candidates)
        if pick not in exclude:
            return pick
    return None


def attach_people(rng, case, roster, channel_id):
    exclude = {case.subject_user_id}
    target = pick_other(rng, roster, channel_id, exclude)
    if target is None:
        return
    case.participants.append((target, "target"))
    exclude.add(target)

    witnesses = []
    if rng.random() < WITNESS_SHARE:
        first = pick_other(rng, roster, channel_id, exclude)
        if first:
            witnesses.append(first)
            exclude.add(first)
            if rng.random() < SECOND_WITNESS_SHARE:
                second = pick_other(rng, roster, channel_id, exclude)
                if second:
                    witnesses.append(second)
                    exclude.add(second)
    for witness in witnesses:
        case.participants.append((witness, "witness"))

    roll = rng.random()
    if roll < REPORTER_IS_TARGET_SHARE:
        case.participants.append((target, "reporter"))
    elif roll < REPORTER_IS_TARGET_SHARE + REPORTER_IS_WITNESS_SHARE and witnesses:
        case.participants.append((witnesses[0], "reporter"))


def build_cases(rng, members, as_of):
    pool = firefighters(members)
    if not pool:
        return []
    roster = channel_roster(members)
    horizon = datetime.combine(as_of, time(23, 59), tzinfo=timezone.utc)
    by_id = {m.user_id: m for m in members}
    built = []
    index = 0

    def settle(case, opened_at):
        takes = min(rng.expovariate(1.0 / MEAN_RESOLVE_DAYS), MAX_RESOLVE_DAYS)
        would_resolve = opened_at + timedelta(days=takes)
        if rng.random() < CLAIMED_SHARE:
            case.claimed_by = rng.choice(pool)
            case.claimed_at = opened_at + timedelta(days=takes * CLAIM_FRACTION * rng.random())
        if would_resolve <= horizon:
            case.resolution = pick_resolution(rng)
            case.resolved_at = would_resolve
            case.member_note = (
                f"[seed] closed as {case.resolution}. synthetic text, not a real outcome"
            )
        elif case.claimed_at and case.claimed_at > horizon:
            case.claimed_by = case.claimed_at = None

    for member in pick_subjects(rng, members):
        if not member.home_channels:
            continue
        for priors, day in enumerate(open_days(rng, member, as_of, case_count(rng))):
            index += 1
            opened_at = moment(rng, day)
            channel_id = rng.choice(member.home_channels).channel_id
            primary_ts = slack_ts(rng, opened_at)
            case = SeedCase(
                external_ref=f"{SEED_REF_PREFIX}case:{index}",
                subject_user_id=None if rng.random() < NO_SUBJECT_SHARE else member.user_id,
                opened_by=rng.choice(pool),
                opened_at=opened_at,
                context=context_for(member, priors, opened_at),
            )
            settle(case, opened_at)
            case.threads.append((channel_id, primary_ts, True, case.opened_by))
            if rng.random() < SECOND_THREAD_SHARE and len(member.home_channels) > 1:
                other = rng.choice(
                    [c for c in member.home_channels if c.channel_id != channel_id]
                )
                case.threads.append(
                    (other.channel_id, slack_ts(rng, opened_at), False, rng.choice(pool))
                )
            attach_people(rng, case, roster, channel_id)
            built.append(case)

            piled_on = [u for u, role in case.participants if role == "witness"]
            if piled_on and rng.random() < SIBLING_SHARE:
                index += 1
                sibling_subject = piled_on[0]
                sibling_at = opened_at + timedelta(minutes=rng.uniform(5, 90))
                if sibling_at > horizon:
                    continue
                sibling = SeedCase(
                    external_ref=f"{SEED_REF_PREFIX}case:{index}",
                    subject_user_id=sibling_subject,
                    opened_by=case.opened_by,
                    opened_at=sibling_at,
                    context=context_for(by_id[sibling_subject], 0, sibling_at),
                )
                settle(sibling, sibling_at)
                sibling.threads.append((channel_id, primary_ts, True, sibling.opened_by))
                for user_id, role in case.participants:
                    if user_id != sibling_subject and role in ("target", "witness"):
                        sibling.participants.append((user_id, role))
                built.append(sibling)

    return built


def case_row(case):
    return (
        case.subject_user_id,
        case.opened_by,
        case.opened_at,
        case.claimed_by,
        case.claimed_at,
        case.resolved_at,
        case.resolution,
        case.member_note,
        json.dumps(case.context),
        "fire_engine",
        case.external_ref,
        case.opened_at,
        case.resolved_at or case.claimed_at or case.opened_at,
    )


def thread_rows(cases, ids):
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        for channel_id, thread_ts, is_primary, added_by in case.threads:
            yield (case_id, channel_id, thread_ts, is_primary, added_by)


def participant_rows(cases, ids):
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        for user_id, role in case.participants:
            yield (case_id, user_id, role)
