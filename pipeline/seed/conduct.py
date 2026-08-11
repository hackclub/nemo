import json
import random
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


def rng_for(seed):
    return random.Random(f"{seed}:conduct")


def firefighters(members, count=FIREFIGHTER_COUNT):
    ranked = sorted(
        (m for m in members if not m.is_bot),
        key=lambda m: (-m.engagement, m.user_id),
    )
    return [m.user_id for m in ranked[:count]]


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


def context_for(member, priors, at):
    return {
        "tenure_days": max((at.date() - member.cohort_at).days, 0),
        "total_messages": member.total_messages,
        "channels": len(member.home_channels),
        "priors": priors,
        "captured_at": at.isoformat(),
    }


def case_rows(rng, members, as_of):
    pool = firefighters(members)
    if not pool:
        return
    horizon = datetime.combine(as_of, time(23, 59), tzinfo=timezone.utc)
    index = 0
    for member in pick_subjects(rng, members):
        for priors, day in enumerate(open_days(rng, member, as_of, case_count(rng))):
            index += 1
            opened_at = moment(rng, day)
            opened_by = rng.choice(pool)
            takes = min(rng.expovariate(1.0 / MEAN_RESOLVE_DAYS), MAX_RESOLVE_DAYS)
            would_resolve = opened_at + timedelta(days=takes)
            claimed_by = claimed_at = None
            if rng.random() < CLAIMED_SHARE:
                claimed_by = rng.choice(pool)
                claimed_at = opened_at + timedelta(
                    days=takes * CLAIM_FRACTION * rng.random()
                )
            resolved_at = resolution = member_note = None
            if would_resolve <= horizon:
                resolution = pick_resolution(rng)
                resolved_at = would_resolve
                member_note = f"[seed] closed as {resolution}. synthetic text, not a real outcome"
            elif claimed_at and claimed_at > horizon:
                claimed_by = claimed_at = None
            subject = None if rng.random() < NO_SUBJECT_SHARE else member.user_id
            yield (
                subject,
                opened_by,
                opened_at,
                claimed_by,
                claimed_at,
                resolved_at,
                resolution,
                member_note,
                json.dumps(context_for(member, priors, opened_at)),
                "fire_engine",
                f"{SEED_REF_PREFIX}case:{index}",
                opened_at,
                resolved_at or claimed_at or opened_at,
            )
