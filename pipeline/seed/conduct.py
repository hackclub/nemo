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
OPEN_CLAIMED_SHARE = 0.55
MIN_UNASSIGNED_OPEN = 2
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
ANON_WHEN_UNREPORTED_SHARE = 0.6
CROWD_SHARE = 0.06
CROWD_EXTRA = (2, 4)
ANON_EXTRA_SHARE = 0.5
REPLIED_SHARE = 0.75
MEAN_REPLY_HOURS = 6.0
REPORT_LEAD_MINUTES = (3, 180)

ACTION_LADDER = ("warning", "shush", "temp_ban", "indef_ban", "perma_ban")
EXPIRING_DAYS = {"shush": (7, 7), "temp_ban": (30, 120)}
SEVERE_SHARE = 0.04
OPEN_WITH_ACTION_SHARE = 0.4
SECOND_ACTION_SHARE = 0.3
DM_TO_TARGET_SHARE = 0.25
LOCK_THREAD_SHARE = 0.2
REVERSED_SHARE = 0.06
FIREHOSE_SHARE = 0.1
BOT_ACTOR = "UMNEMOSYNE"
EVIDENCE = "evidence"
INTERNAL = "internal"
FD_CHANNEL = "CSEEDFIREHOUSE"
INTERNAL_THREAD_SHARE = 0.25
SECOND_INTERNAL_SHARE = 0.2
SHARED_INTERNAL_SHARE = 0.35
MIN_SHARED_EVIDENCE = 3
FD_LAG_MINUTES = (5.0, 240.0)
CASE_NOTE_SHARE = 0.45
SECOND_NOTE_SHARE = 0.25
NOTE_DELETED_SHARE = 0.05
STANDING_NOTE_SHARE = 0.35
NOTE_DELETE_HOURS = (1.0, 72.0)
STANDING_NOTE_LAG_DAYS = (0.5, 14.0)

CASE_NOTE_BODIES = (
    "spoke to them in DM, they understood and apologised",
    "second read of the thread, less clear cut than the report makes it sound",
    "reporter asked to stay out of it, keeping them off the thread",
    "they had a rough week in another channel. not an excuse, but worth knowing",
    "asked the channel regulars, this was out of character for them",
    "waiting for the target to come back online before deciding anything",
    "thread had already cooled off by the time we got to it",
    "asked a second firefighter to read this before I act",
)

STANDING_NOTE_BODIES = (
    "escalates when corrected in public, a soft word early goes further",
    "has come up more than once now, none of it severe on its own",
    "asked not to be pinged into pile-ons, honour that",
    "usually fine. the pattern is late-night posts",
    "much better since the first case, keep that in mind on any next one",
)
REVERSAL_REASONS = (
    "[seed] appeal upheld",
    "[seed] issued against the wrong account",
    "[seed] lifted early after a conversation",
)

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

NOTE_COLUMNS = [
    "case_id",
    "subject_user_id",
    "body",
    "author",
    "created_at",
    "updated_at",
    "deleted_at",
    "deleted_by",
]

AUDIT_COLUMNS = [
    "occurred_at",
    "actor_user_id",
    "actor_kind",
    "entity_type",
    "entity_id",
    "verb",
    "before",
    "after",
    "source_app",
    "request_id",
]

THREAD_COLUMNS = ["case_id", "channel_id", "thread_ts", "kind", "is_primary", "added_by"]
PARTICIPANT_COLUMNS = ["case_id", "user_id", "role"]
REPORT_COLUMNS = [
    "case_id",
    "reporter_user_id",
    "is_anonymous",
    "body",
    "received_at",
    "dm_channel_id",
    "dm_ts",
    "forwarded_ts",
    "first_replied_at",
    "closed_at",
    "source_app",
    "external_ref",
]


ACTION_COLUMNS = [
    "case_id",
    "type_key",
    "target_user_id",
    "decided_by",
    "performed_by",
    "performed_at",
    "source_app",
    "expires_at",
    "reversed_at",
    "reversed_by",
    "reversal_reason",
    "subject_context",
    "details",
    "external_ref",
]


@dataclass
class SeedAction:
    type_key: str
    target_user_id: str
    decided_by: str
    performed_by: str
    performed_at: datetime
    source_app: str
    subject_context: dict
    details: dict
    expires_at: datetime | None = None
    reversed_at: datetime | None = None
    reversed_by: str | None = None
    reversal_reason: str | None = None


@dataclass
class SeedReport:
    reporter_user_id: str | None
    is_anonymous: bool
    body: str
    received_at: datetime
    dm_channel_id: str | None
    dm_ts: str | None
    forwarded_ts: str
    first_replied_at: datetime | None
    closed_at: datetime | None
    source_app: str


@dataclass
class SeedNote:
    body: str
    author: str
    created_at: datetime
    subject_user_id: str | None = None
    deleted_at: datetime | None = None
    deleted_by: str | None = None


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
    reports: list = field(default_factory=list)
    actions: list = field(default_factory=list)
    notes: list = field(default_factory=list)


def rng_for(seed, stream="conduct"):
    return random.Random(f"{seed}:{stream}")


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


def dm_channel_for(user_id):
    return f"D{user_id[1:]}"


def make_report(rng, case, reporter, source_app="shroud"):
    received_at = case.opened_at - timedelta(minutes=rng.uniform(*REPORT_LEAD_MINUTES))
    anonymous = reporter is None
    replied_at = None
    if rng.random() < REPLIED_SHARE:
        replied_at = received_at + timedelta(hours=rng.expovariate(1.0 / MEAN_REPLY_HOURS))
        if case.resolved_at and replied_at > case.resolved_at:
            replied_at = case.resolved_at
    return SeedReport(
        reporter_user_id=reporter,
        is_anonymous=anonymous,
        body="[seed] report text, synthetic, not a real account of anything",
        received_at=received_at,
        dm_channel_id=None if anonymous else dm_channel_for(reporter),
        dm_ts=slack_ts(rng, received_at),
        forwarded_ts=slack_ts(rng, received_at),
        first_replied_at=replied_at,
        closed_at=case.resolved_at,
        source_app=source_app,
    )


def attach_reports(rng, case, roster):
    named = [user_id for user_id, role in case.participants if role == "reporter"]
    if named:
        case.reports.append(make_report(rng, case, named[0]))
    elif rng.random() < ANON_WHEN_UNREPORTED_SHARE:
        case.reports.append(make_report(rng, case, None))

    if not case.reports or rng.random() >= CROWD_SHARE:
        return

    channel_id = case.threads[0][0] if case.threads else None
    exclude = {case.subject_user_id, *named}
    for _ in range(rng.randint(*CROWD_EXTRA)):
        if channel_id is None or rng.random() < ANON_EXTRA_SHARE:
            case.reports.append(make_report(rng, case, None))
            continue
        extra = pick_other(rng, roster, channel_id, exclude)
        if extra is None:
            continue
        exclude.add(extra)
        case.reports.append(make_report(rng, case, extra))
        case.participants.append((extra, "reporter"))


def attach_all_reports(rng, cases, members):
    roster = channel_roster(members)
    for case in cases:
        attach_reports(rng, case, roster)
    return cases


def action_context(case, at):
    context = dict(case.context)
    context["captured_at"] = at.isoformat()
    return context


def rung_type(rng, priors):
    if rng.random() < SEVERE_SHARE:
        return rng.choice(ACTION_LADDER[-2:])
    top = min(priors, len(ACTION_LADDER) - 1)
    if top > 0 and rng.random() < 0.35:
        top -= 1
    return ACTION_LADDER[top]


def action_window(case, horizon):
    start = case.claimed_at or case.opened_at
    end = case.resolved_at or horizon
    if end <= start:
        end = start + timedelta(minutes=30)
    return start, end


def action_moment(rng, start, end):
    span = max((end - start).total_seconds(), 60.0)
    return start + timedelta(seconds=rng.uniform(0, span))


def make_action(rng, case, type_key, target, at, decider, performed_by=None, details=None):
    action = SeedAction(
        type_key=type_key,
        target_user_id=target,
        decided_by=decider,
        performed_by=performed_by or decider,
        performed_at=at,
        source_app="fire_engine",
        subject_context=action_context(case, at),
        details=details or {},
    )
    if type_key in EXPIRING_DAYS:
        low, high = EXPIRING_DAYS[type_key]
        action.expires_at = at + timedelta(days=rng.uniform(low, high))
    if rng.random() < REVERSED_SHARE:
        action.reversed_at = at + timedelta(days=rng.uniform(0.5, 20))
        action.reversed_by = decider
        action.reversal_reason = rng.choice(REVERSAL_REASONS)
    return action


def attach_actions(rng, case, horizon):
    if case.subject_user_id is None:
        return
    if case.resolution in ("no_action", "duplicate", "not_conduct"):
        return
    if case.resolution is None and rng.random() >= OPEN_WITH_ACTION_SHARE:
        return

    decider = case.claimed_by or case.opened_by
    start, end = action_window(case, horizon)
    priors = case.context.get("priors", 0)

    at = action_moment(rng, start, end)
    primary = make_action(rng, case, rung_type(rng, priors), case.subject_user_id, at, decider)
    if rng.random() < FIREHOSE_SHARE:
        primary.source_app = "firehose"
        primary.performed_by = BOT_ACTOR
    case.actions.append(primary)

    channel_id = case.threads[0][0] if case.threads else None
    if channel_id and rng.random() < LOCK_THREAD_SHARE:
        case.actions.append(
            make_action(
                rng, case, "locked_thread", case.subject_user_id,
                action_moment(rng, start, end), decider,
                performed_by=BOT_ACTOR, details={"channel_id": channel_id},
            )
        )

    target = next((u for u, role in case.participants if role == "target"), None)
    if target and rng.random() < DM_TO_TARGET_SHARE:
        case.actions.append(
            make_action(rng, case, "dm", target, action_moment(rng, start, end), decider)
        )

    if rng.random() < SECOND_ACTION_SHARE and channel_id:
        case.actions.append(
            make_action(
                rng, case, "channel_ban", case.subject_user_id,
                action_moment(rng, start, end), decider,
                details={"channel_id": channel_id},
            )
        )


def attach_all_actions(rng, cases, as_of):
    horizon = datetime.combine(as_of, time(23, 59), tzinfo=timezone.utc)
    for case in cases:
        attach_actions(rng, case, horizon)
    return cases


def attach_internal_threads(rng, cases, members):
    crew = firefighters(members)
    if not crew:
        return cases

    seen = []
    for case in cases:
        if rng.random() >= INTERNAL_THREAD_SHARE:
            continue

        rounds = 2 if rng.random() < SECOND_INTERNAL_SHARE else 1
        for _ in range(rounds):
            if seen and rng.random() < SHARED_INTERNAL_SHARE:
                thread_ts = rng.choice(seen)
            else:
                at = case.opened_at + timedelta(minutes=rng.uniform(*FD_LAG_MINUTES))
                thread_ts = slack_ts(rng, at)
                seen.append(thread_ts)

            case.threads.append(
                (FD_CHANNEL, thread_ts, INTERNAL, False, rng.choice(crew))
            )
    return cases


def primary_of(case):
    for thread in case.threads:
        if thread[2] == EVIDENCE and thread[3]:
            return thread
    return None


def shared_evidence_count(cases):
    seen = collections.Counter()
    for case in cases:
        for channel_id, thread_ts, kind, _, _ in case.threads:
            if kind == EVIDENCE:
                seen[(channel_id, thread_ts)] += 1
    return sum(1 for count in seen.values() if count > 1)


def attach_shared_evidence(rng, cases, minimum=MIN_SHARED_EVIDENCE):
    shortfall = minimum - shared_evidence_count(cases)
    if shortfall <= 0:
        return cases

    eligible = [case for case in cases if primary_of(case)]
    if len(eligible) < 2:
        return cases

    made = 0
    for _ in range(shortfall * 20):
        if made >= shortfall:
            break

        source, target = rng.sample(eligible, 2)
        channel_id, thread_ts = primary_of(source)[:2]
        if any(t[0] == channel_id and t[1] == thread_ts for t in target.threads):
            continue

        target.threads.append(
            (channel_id, thread_ts, EVIDENCE, False, target.opened_by)
        )
        made += 1

    return cases


def free_open_cases(rng, cases, minimum=MIN_UNASSIGNED_OPEN):
    still_open = [case for case in cases if case.resolved_at is None]
    shortfall = minimum - sum(1 for case in still_open if case.claimed_at is None)
    if shortfall <= 0:
        return cases

    claimed = [case for case in still_open if case.claimed_at is not None]
    rng.shuffle(claimed)
    for case in claimed[:shortfall]:
        case.claimed_by = case.claimed_at = None
    return cases


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
        resolves = would_resolve <= horizon
        if rng.random() < (CLAIMED_SHARE if resolves else OPEN_CLAIMED_SHARE):
            case.claimed_by = rng.choice(pool)
            case.claimed_at = opened_at + timedelta(days=takes * CLAIM_FRACTION * rng.random())
        if resolves:
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
            case.threads.append((channel_id, primary_ts, EVIDENCE, True, case.opened_by))
            if rng.random() < SECOND_THREAD_SHARE and len(member.home_channels) > 1:
                other = rng.choice(
                    [c for c in member.home_channels if c.channel_id != channel_id]
                )
                case.threads.append(
                    (
                        other.channel_id,
                        slack_ts(rng, opened_at),
                        EVIDENCE,
                        False,
                        rng.choice(pool),
                    )
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
                sibling.threads.append(
                    (channel_id, primary_ts, EVIDENCE, True, sibling.opened_by)
                )
                for user_id, role in case.participants:
                    if user_id != sibling_subject and role in ("target", "witness"):
                        sibling.participants.append((user_id, role))
                built.append(sibling)

    return free_open_cases(rng, built)


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
        for channel_id, thread_ts, kind, is_primary, added_by in case.threads:
            yield (case_id, channel_id, thread_ts, kind, is_primary, added_by)


def participant_rows(cases, ids):
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        for user_id, role in case.participants:
            yield (case_id, user_id, role)


def action_rows(cases, ids):
    index = 0
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        for action in case.actions:
            index += 1
            yield (
                case_id,
                action.type_key,
                action.target_user_id,
                action.decided_by,
                action.performed_by,
                action.performed_at,
                action.source_app,
                action.expires_at,
                action.reversed_at,
                action.reversed_by,
                action.reversal_reason,
                json.dumps(action.subject_context),
                json.dumps(action.details),
                f"{SEED_REF_PREFIX}action:{index}",
            )


def report_rows(cases, ids):
    index = 0
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        for report in case.reports:
            index += 1
            yield (
                case_id,
                report.reporter_user_id,
                report.is_anonymous,
                report.body,
                report.received_at,
                report.dm_channel_id,
                report.dm_ts,
                report.forwarded_ts,
                report.first_replied_at,
                report.closed_at,
                report.source_app,
                f"{SEED_REF_PREFIX}report:{index}",
            )


def note_moment(rng, case, horizon):
    start, end = action_window(case, horizon)
    return start + timedelta(seconds=rng.uniform(0, (end - start).total_seconds()))


def note_author(rng, case, crew):
    for candidate in (case.claimed_by, case.opened_by):
        if candidate and candidate != BOT_ACTOR:
            return candidate
    return rng.choice(crew)


def attach_notes(rng, case, crew, horizon):
    if rng.random() >= CASE_NOTE_SHARE:
        return
    count = 2 if rng.random() < SECOND_NOTE_SHARE else 1
    for _ in range(count):
        created_at = note_moment(rng, case, horizon)
        author = note_author(rng, case, crew)
        deleted_at = None
        deleted_by = None
        if rng.random() < NOTE_DELETED_SHARE:
            deleted_at = min(
                created_at + timedelta(hours=rng.uniform(*NOTE_DELETE_HOURS)), horizon
            )
            deleted_by = author
        case.notes.append(
            SeedNote(
                body=rng.choice(CASE_NOTE_BODIES),
                author=author,
                created_at=created_at,
                deleted_at=deleted_at,
                deleted_by=deleted_by,
            )
        )


def standing_notes(rng, cases, crew, horizon):
    latest = {}
    for case in cases:
        if not case.subject_user_id:
            continue
        seen = latest.get(case.subject_user_id)
        latest[case.subject_user_id] = (
            case.opened_at if seen is None else max(seen, case.opened_at)
        )
    counts = collections.Counter(
        case.subject_user_id for case in cases if case.subject_user_id
    )
    notes = []
    for user_id in sorted(latest):
        if counts[user_id] < 2 or rng.random() >= STANDING_NOTE_SHARE:
            continue
        lag = timedelta(days=rng.uniform(*STANDING_NOTE_LAG_DAYS))
        notes.append(
            SeedNote(
                body=rng.choice(STANDING_NOTE_BODIES),
                author=rng.choice(crew),
                created_at=min(latest[user_id] + lag, horizon),
                subject_user_id=user_id,
            )
        )
    return notes


def attach_all_notes(rng, cases, members, as_of):
    horizon = datetime.combine(as_of, time(23, 59), tzinfo=timezone.utc)
    crew = firefighters(members)
    for case in cases:
        attach_notes(rng, case, crew, horizon)
    return standing_notes(rng, cases, crew, horizon)


def note_rows(cases, ids, standing):
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        for note in case.notes:
            yield (
                case_id,
                None,
                note.body,
                note.author,
                note.created_at,
                note.deleted_at or note.created_at,
                note.deleted_at,
                note.deleted_by,
            )
    for note in standing:
        yield (
            None,
            note.subject_user_id,
            note.body,
            note.author,
            note.created_at,
            note.created_at,
            None,
            None,
        )


def actor_kind(user_id):
    if user_id is None:
        return "system"
    return "bot" if user_id == BOT_ACTOR else "human"


def audit_entry(at, actor, entity_type, entity_id, verb, before, after, source_app, request):
    return (
        at,
        actor,
        actor_kind(actor),
        entity_type,
        entity_id,
        verb,
        None if before is None else json.dumps(before),
        None if after is None else json.dumps(after),
        source_app,
        request,
    )


def case_audit(case, case_id):
    request = f"{SEED_REF_PREFIX}audit:case:{case_id}"
    yield audit_entry(
        case.opened_at, case.opened_by, "case", case_id, "opened",
        None, {"subject_user_id": case.subject_user_id}, "fire_engine", f"{request}:opened",
    )
    if case.claimed_at:
        yield audit_entry(
            case.claimed_at, case.claimed_by, "case", case_id, "claimed",
            {"claimed_by": None}, {"claimed_by": case.claimed_by},
            "fire_engine", f"{request}:claimed",
        )
    if case.resolved_at:
        yield audit_entry(
            case.resolved_at, case.claimed_by or case.opened_by, "case", case_id, "resolved",
            {"resolution": None}, {"resolution": case.resolution},
            "fire_engine", f"{request}:resolved",
        )


def action_audit(action, action_id, request):
    yield audit_entry(
        action.performed_at, action.performed_by, "action", action_id, "performed",
        None,
        {
            "type_key": action.type_key,
            "target_user_id": action.target_user_id,
            "expires_at": action.expires_at.isoformat() if action.expires_at else None,
        },
        action.source_app, f"{request}:performed",
    )
    if action.reversed_at:
        yield audit_entry(
            action.reversed_at, action.reversed_by, "action", action_id, "reversed",
            {"reversed_at": None},
            {"reversed_at": action.reversed_at.isoformat(), "reason": action.reversal_reason},
            "fire_engine", f"{request}:reversed",
        )


def audit_rows(cases, ids, action_ids, report_ids):
    action_index = 0
    report_index = 0
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        yield from case_audit(case, case_id)
        for report in case.reports:
            report_index += 1
            report_id = report_ids.get(f"{SEED_REF_PREFIX}report:{report_index}")
            if report_id is None:
                continue
            yield audit_entry(
                report.received_at, None, "report", report_id, "received",
                None, {"is_anonymous": report.is_anonymous},
                report.source_app, f"{SEED_REF_PREFIX}audit:report:{report_id}",
            )
        for action in case.actions:
            action_index += 1
            action_id = action_ids.get(f"{SEED_REF_PREFIX}action:{action_index}")
            if action_id is None:
                continue
            yield from action_audit(
                action, action_id, f"{SEED_REF_PREFIX}audit:action:{action_id}"
            )
