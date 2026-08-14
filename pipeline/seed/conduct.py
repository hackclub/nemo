import collections
import json
import random
from dataclasses import dataclass, field
from datetime import datetime, time, timedelta, timezone

from seed import SEED_REF_PREFIX, SEED_SOURCE_PREFIX

CASE_RATE = 0.025
ENGAGEMENT_WEIGHT = 0.7
FIREFIGHTER_COUNT = 5
LEAD_COUNT = 2
GRANT_AGE_DAYS = (60, 400)
DORMANT_GRANT_DAYS = 124
ENDED_GRANT_DAYS = (280, 70)
REFUSALS_EACH = (0, 2)
REFUSAL_WINDOW_DAYS = 26.0
REFUSED_KEYS = ("decision.settle", "decision.retire", "access.grant")
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
INVOLVED_SHARE = 0.45
SECOND_INVOLVED_SHARE = 0.15
AIMED_AT = "it was aimed at them"
TOOK_PART = "took part in the thread"
REPORTER_IS_TARGET_SHARE = 0.5
REPORTER_IS_INVOLVED_SHARE = 0.25
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
REFERENCE = "reference"
DECISION_SETTLE_DAYS = (1.0, 6.0)
DECISION_SECOND_INTERNAL_SHARE = 0.4
DECISION_REFERENCE_SHARE = 0.6
DECISION_FOLLOW_SHARE = 0.3
DECISION_BEHIND_PROPOSAL = (1, 3)
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
DECISION_LIBRARY = (
    {
        "title": "Spam accounts",
        "statement": "A first-post account posting an invite link is banned on sight, "
                     "with no warning, and the thread is locked.",
        "category_key": "spam",
        "reasons": (
            "warning a throwaway account does nothing, it is abandoned within the hour",
            "three of us handled the same wave three different ways in one afternoon",
            "a real member caught by this can appeal, and the ban is cheap to reverse",
        ),
        "state": "settled",
        "age_days": 180,
        "replaces": "Warnings by DM",
    },
    {
        "title": "Warnings by DM",
        "statement": "Every warning goes by DM, never in the channel it happened in.",
        "category_key": None,
        "reasons": ("a public warning turns one bad message into a thread about us",),
        "state": "superseded",
        "age_days": 320,
    },
    {
        "title": "Pile-ons",
        "statement": "A pile-on gets one thread lock and a note to the loudest three, "
                     "not five separate cases.",
        "category_key": "harassment_general",
        "reasons": (
            "five cases for one thread is bookkeeping, not conduct work",
            "the quiet ones stop reading when everybody gets a case",
        ),
        "state": "settled",
        "age_days": 240,
    },
    {
        "title": "Night shift",
        "statement": "Nothing worse than a warning is acted on alone after midnight. "
                     "Write the note and hand it over.",
        "category_key": None,
        "reasons": (
            "every reversal this year was decided after 1am by somebody working alone",
        ),
        "state": "settled",
        "age_days": 90,
    },
    {
        "title": "Minors in DMs",
        "statement": "An adult messaging a minor privately goes straight to staff, "
                     "with no ladder and no delay.",
        "category_key": "adult",
        "reasons": (
            "this is not ours to weigh up, it is theirs to act on",
            "the ladder exists to give people a chance to correct, which does not apply here",
        ),
        "state": "settled",
        "age_days": 300,
    },
    {
        "title": "Alt accounts",
        "statement": "A ban covers the person, not the account, so a new account is the same ban.",
        "category_key": "ban_evasion",
        "reasons": ("otherwise the ladder resets every time somebody signs up again",),
        "state": "settled",
        "age_days": 140,
    },
    {
        "title": "Appeals",
        "statement": "An appeal is read by somebody who was not on the case. "
                     "If nobody else is free, it waits.",
        "category_key": None,
        "reasons": (
            "the person who decided it has already made up their mind",
            "waiting a day costs less than a reversal nobody trusts",
        ),
        "state": "proposed",
        "age_days": 12,
    },
    {
        "title": "Screenshots as evidence",
        "statement": "A screenshot on its own is never enough to act. Ask for the permalink.",
        "category_key": None,
        "reasons": ("we have been handed two edited screenshots this month",),
        "state": "proposed",
        "age_days": 5,
    },
)

DECISION_THREAD_REASONS = {
    "first": "where it was decided",
    "second": "the objection two weeks later",
    "reference": "the thread that started it",
}

REVERSAL_REASONS = (
    "appeal upheld, the thread reads differently with the context they gave",
    "issued against the wrong account, same display name",
    "lifted early after a conversation, they get it",
    "shouldn't have been a shush, a warning was enough",
)

REPORT_BODIES = (
    "can someone look at the thread i linked, it's getting nasty in there",
    "third spam account today, this one is posting invite links",
    "they've been at me all week in that channel and i'm done arguing",
    "someone should say something before this turns into a pile on",
    "not sure this is worth a report but the tone in there is off",
    "screenshot in the thread. second time from the same person",
    "reporting it so it's written down somewhere, i don't want anything to happen",
    "can a firefighter take a look, i don't want to reply and make it worse",
    "i blocked them but they're still going in the thread",
    "this is the person i mentioned on the call",
)

RESOLUTION_NOTES = {
    "action_taken": (
        "warned them, they took it fine",
        "shushed for a week, they'd been told once before",
        "removed from the channel, the thread is locked",
    ),
    "no_action": (
        "read the thread twice, it's blunt but not a conduct matter",
        "both sides were rude, told them both to drop it",
        "nothing here beyond a bad day, no action",
    ),
    "duplicate": (
        "same thread as the earlier case, folded into that one",
        "already handled under the other case",
    ),
    "not_conduct": (
        "a support question, pointed them at the right channel",
        "moderation on their own server, not ours",
    ),
}

RESOLUTION_WEIGHTS = (
    ("action_taken", 0.55),
    ("no_action", 0.28),
    ("duplicate", 0.11),
    ("not_conduct", 0.06),
)

CASE_COLUMNS = [
    "opened_by",
    "opened_at",
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

DECISION_COLUMNS = [
    "title",
    "statement",
    "category_key",
    "reasons",
    "state",
    "proposed_by",
    "proposed_at",
    "settled_by",
    "settled_at",
    "retired_by",
    "retired_at",
    "created_at",
    "updated_at",
]

DECISION_THREAD_COLUMNS = [
    "decision_id",
    "channel_id",
    "thread_ts",
    "why",
    "kind",
    "added_by",
    "added_at",
]

GRANT_COLUMNS = [
    "user_id",
    "role",
    "reason",
    "granted_by",
    "granted_at",
    "revoked_by",
    "revoked_at",
]

MESSAGE_COLUMNS = [
    "channel_id",
    "thread_ts",
    "message_ts",
    "parent_ts",
    "is_root",
    "author_user_id",
    "subtype",
    "body",
    "file_count",
    "permalink",
    "reply_count",
    "posted_at",
    "edited_at",
    "deleted_at",
    "source_app",
]

THREAD_OPENERS = [
    "anyone know why the deploy keeps failing on the same step",
    "is the wifi working for anyone else or just me",
    "shipped my first pcb today, the traces are ugly but it works",
    "how do i get an api key for this, the docs link is dead",
    "builds fine locally, dies in ci. what am i missing",
    "does anyone have the link for tonight's call",
    "spent 3 hours on a semicolon. that's it, that's the message",
    "is there a rule against posting wips here",
]

BARBS = [
    "maybe read the error message for once",
    "how are you this bad at googling",
    "nobody asked",
    "cry about it",
    "genuinely how do you not know this yet",
    "some of you should not be allowed near a keyboard",
    "free nitro for the first 20 people who join my server",
    "dm me for the giveaway, not a scam",
]

PILE_ON = [
    "lmao",
    "+1",
    "^",
    "brutal",
    "not wrong tho",
]

CALLOUTS = [
    "not cool",
    "come on man",
    "that's uncalled for",
    "reporting this",
    "third one today",
]

SECOND_BARBS = [
    "it was a joke, relax",
    "ok that came out worse than i meant",
    "whatever, deleting",
]

FD_OPENERS = [
    "who's taking this one",
    "second opinion on this before i do anything",
    "third time this month for them, worth a look",
    "picking this up unless someone else already has",
]

FD_TAKING = [
    "i can take it",
    "mine, give me ten minutes",
    "on it",
]

FD_DECIDED = [
    "warned them, watching the thread",
    "locked it, they kept going after the warning",
    "the nov one was reversed so i wouldn't count it",
    "leaving the other one alone, it was one word",
    "not a conduct thing imo, just a bad day",
]

FD_AFTER = [
    "dm sent, they apologised",
    "somebody should reply to the reporter, they've heard nothing",
    "closing it unless anyone objects",
]

MESSAGE_REPLIES = (1, 4)
MESSAGE_GAP_SECONDS = (25.0, 480.0)
MESSAGE_DELETED_SHARE = 0.07
MESSAGE_EDITED_SHARE = 0.05
MESSAGE_FILE_SHARE = 0.1
PARTIAL_FETCH_SHARE = 0.15
MESSAGE_SOURCE = f"{SEED_SOURCE_PREFIX}slack"
PARTICIPANT_COLUMNS = ["case_id", "user_id", "role", "detail"]

MEMBER_COLUMNS = [
    "user_id", "handle", "display_name", "title", "pronouns", "avatar_url", "avatar_hash",
    "tz", "tz_offset", "enterprise_id", "team_ids", "is_bot", "is_deleted", "is_admin",
    "is_owner", "is_restricted", "is_ultra_restricted", "profile_updated_at",
]

IDENTITY_COLUMNS = ["user_id", "real_name", "first_name", "last_name", "email"]

SEED_ENTERPRISE = "ESEED00001"
SEED_TEAM = "TSEED00001"
SEED_EMAIL_DOMAIN = "example.invalid"

GIVEN_NAMES = (
    "ada avery bo cyrus dara elio fen gia hal iris jun kai lena milo nadia orla pax quinn "
    "rune sam tess uma vero wren xio yuki zev"
).split()

FAMILY_NAMES = (
    "ainsley brook chen delgado eskildsen faraday gallo hollis ibarra jensen kovac lindqvist "
    "moreno nakamura okafor pereira quiroga ridley sokolov tanaka ueda vasquez whitfield "
    "yamada zielinski"
).split()

PRONOUN_POOL = ("", "", "she/her", "he/him", "they/them", "she/they", "he/they")

TIMEZONES = (
    ("America/New_York", -14400),
    ("America/Los_Angeles", -25200),
    ("Europe/London", 3600),
    ("Africa/Cairo", 10800),
    ("Asia/Kolkata", 19800),
    ("Australia/Sydney", 36000),
)

TITLES = (
    "", "", "", "high school | building things", "ysws enjoyer", "fd | ask me anything",
    "shipping something small", "club leader", "hardware, mostly",
)

NO_DISPLAY_NAME_SHARE = 0.04
CUSTOM_TITLE_SHARE = 0.45

ASSIGNEE_COLUMNS = ["case_id", "user_id", "assigned_at", "assigned_by"]
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
    "closed_by",
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
    closed_by: str | None
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


def quiet_members(members, count):
    ranked = sorted(
        (m for m in members if not m.is_bot),
        key=lambda m: (m.engagement, m.user_id),
    )
    return [m.user_id for m in ranked[:count]]


def access_grants(rng, members, as_of):
    crew = firefighters(members)
    if not crew:
        return []

    horizon = datetime.combine(as_of, time(9, 0), tzinfo=timezone.utc)
    rows = []
    for spot, user_id in enumerate(crew):
        role = "lead" if spot < LEAD_COUNT else "firefighter"
        giver = crew[1] if spot == 0 and len(crew) > 1 else crew[0]
        held = rng.randint(*GRANT_AGE_DAYS)
        rows.append(
            (user_id, role, None, giver, horizon - timedelta(days=held), None, None)
        )

    spare = [user_id for user_id in quiet_members(members, 2) if user_id not in crew]
    if spare:
        rows.append(
            (
                spare[0],
                "firefighter",
                "cover for the night shift",
                crew[0],
                horizon - timedelta(days=DORMANT_GRANT_DAYS),
                None,
                None,
            )
        )
    if len(spare) > 1:
        started, ended = ENDED_GRANT_DAYS
        rows.append(
            (
                spare[1],
                "firefighter",
                "left FD",
                crew[0],
                horizon - timedelta(days=started),
                crew[0],
                horizon - timedelta(days=ended),
            )
        )
    return rows


def refusal_rows(rng, members, as_of):
    crew = firefighters(members)[LEAD_COUNT:]
    horizon = datetime.combine(as_of, time(18, 0), tzinfo=timezone.utc)

    for spot, user_id in enumerate(crew):
        turns = max(rng.randint(*REFUSALS_EACH), 1 if spot == 0 else 0)
        for turn in range(turns):
            at = horizon - timedelta(days=rng.uniform(1.0, REFUSAL_WINDOW_DAYS))
            yield audit_entry(
                at,
                user_id,
                "case",
                0,
                "refused",
                None,
                {"permission": rng.choice(REFUSED_KEYS), "role": "firefighter"},
                "fire_engine",
                f"{SEED_REF_PREFIX}audit:refused:{spot}:{turn}",
            )


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


PRIOR_WINDOW_DAYS = 365


def settle_priors(cases):
    by_subject = collections.defaultdict(list)
    for case in cases:
        if case.subject_user_id:
            by_subject[case.subject_user_id].append(case)

    for owned in by_subject.values():
        owned.sort(key=lambda case: case.opened_at)
        for case in owned:
            case.context["priors"] = sum(
                1
                for other in owned
                if other.resolved_at is not None
                and other.actions
                and other.resolved_at < case.opened_at
                and (case.opened_at - other.resolved_at).days <= PRIOR_WINDOW_DAYS
            )


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
    case.participants.append((target, "involved", AIMED_AT))
    exclude.add(target)

    involved = []
    if rng.random() < INVOLVED_SHARE:
        first = pick_other(rng, roster, channel_id, exclude)
        if first:
            involved.append(first)
            exclude.add(first)
            if rng.random() < SECOND_INVOLVED_SHARE:
                second = pick_other(rng, roster, channel_id, exclude)
                if second:
                    involved.append(second)
                    exclude.add(second)
    for user_id in involved:
        case.participants.append((user_id, "involved", TOOK_PART))

    roll = rng.random()
    if roll < REPORTER_IS_TARGET_SHARE:
        case.participants.append((target, "reporter", None))
    elif roll < REPORTER_IS_TARGET_SHARE + REPORTER_IS_INVOLVED_SHARE and involved:
        case.participants.append((involved[0], "reporter", None))


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
        body=rng.choice(REPORT_BODIES),
        received_at=received_at,
        dm_channel_id=None if anonymous else dm_channel_for(reporter),
        dm_ts=slack_ts(rng, received_at),
        forwarded_ts=slack_ts(rng, received_at),
        first_replied_at=replied_at,
        closed_at=case.resolved_at,
        closed_by=(case.claimed_by or case.opened_by) if case.resolved_at else None,
        source_app=source_app,
    )


def attach_reports(rng, case, roster):
    named = [user_id for user_id, role, _ in case.participants if role == "reporter"]
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
        case.participants.append((extra, "reporter", None))


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

    target = next((u for u, _, detail in case.participants if detail == AIMED_AT), None)
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
            case.member_note = rng.choice(RESOLUTION_NOTES[case.resolution])
        elif case.claimed_at and case.claimed_at > horizon:
            case.claimed_by = case.claimed_at = None

    for member in pick_subjects(rng, members):
        if not member.home_channels:
            continue
        for seq, day in enumerate(open_days(rng, member, as_of, case_count(rng))):
            index += 1
            opened_at = moment(rng, day)
            channel_id = rng.choice(member.home_channels).channel_id
            primary_ts = slack_ts(rng, opened_at)
            case = SeedCase(
                external_ref=f"{SEED_REF_PREFIX}case:{index}",
                subject_user_id=None if rng.random() < NO_SUBJECT_SHARE else member.user_id,
                opened_by=rng.choice(pool),
                opened_at=opened_at,
                context=context_for(member, seq, opened_at),
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

            piled_on = [
                u for u, role, detail in case.participants
                if role == "involved" and detail == TOOK_PART
            ]
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
                for user_id, role, detail in case.participants:
                    if user_id != sibling_subject and role == "involved":
                        sibling.participants.append((user_id, role, detail))
                built.append(sibling)

    return free_open_cases(rng, built)


def case_row(case):
    return (
        case.opened_by,
        case.opened_at,
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


def message_ts_at(rng, at):
    return f"{int(at.timestamp())}.{rng.randrange(1000000):06d}"


def permalink_for(channel_id, message_ts):
    return f"https://hackclub.slack.com/archives/{channel_id}/p{message_ts.replace('.', '')}"


def fd_crew_for(case, added_by):
    crew = [added_by, case.claimed_by, case.opened_by]
    return list(dict.fromkeys(user_id for user_id in crew if user_id))


def internal_script(rng, crew):
    lines = [(crew[0], rng.choice(FD_OPENERS))]
    banks = [FD_TAKING, FD_DECIDED]
    if rng.random() < 0.6:
        banks.append(FD_AFTER)
    if len(banks) < MESSAGE_REPLIES[1] and rng.random() < 0.4:
        banks.insert(2, FD_DECIDED)

    for bank in banks:
        lines.append((crew[len(lines) % len(crew)], rng.choice(bank)))
    return lines


def evidence_script(rng, case, reporters, involved):
    opener = (reporters or involved or [case.subject_user_id])[0]
    lines = [(opener, rng.choice(THREAD_OPENERS))]

    if case.subject_user_id:
        lines.append((case.subject_user_id, rng.choice(BARBS)))
    for user_id in [person for person in involved if person != opener][:2]:
        if rng.random() < 0.7:
            lines.append((user_id, rng.choice(PILE_ON)))
    if reporters and rng.random() < 0.7:
        lines.append((reporters[0], rng.choice(CALLOUTS)))
    if case.subject_user_id and rng.random() < 0.35:
        lines.append((case.subject_user_id, rng.choice(SECOND_BARBS)))

    return lines[: 1 + MESSAGE_REPLIES[1]]


def thread_messages(rng, case, channel_id, thread_ts, kind, added_by):
    if kind == INTERNAL:
        crew = fd_crew_for(case, added_by)
        script = internal_script(rng, crew) if crew else []
    else:
        script = evidence_script(
            rng, case,
            [user_id for user_id, role, _ in case.participants if role == "reporter"],
            [user_id for user_id, role, _ in case.participants if role == "involved"],
        )
    if not script or script[0][0] is None:
        return

    at = datetime.fromtimestamp(float(thread_ts), tz=timezone.utc)
    held = len(script) - 1
    reported = held
    if rng.random() < PARTIAL_FETCH_SHARE:
        reported = held + rng.randrange(1, 7)

    for index, (author, body) in enumerate(script):
        root = index == 0
        message_ts = thread_ts if root else message_ts_at(rng, at)
        edited_at = at + timedelta(minutes=rng.uniform(1, 30)) if (
            rng.random() < MESSAGE_EDITED_SHARE
        ) else None
        deleted_at = at + timedelta(hours=rng.uniform(0.5, 48)) if (
            not root and rng.random() < MESSAGE_DELETED_SHARE
        ) else None

        yield (
            channel_id,
            thread_ts,
            message_ts,
            None if root else thread_ts,
            root,
            author,
            None,
            body,
            1 if rng.random() < MESSAGE_FILE_SHARE else 0,
            permalink_for(channel_id, message_ts),
            reported if root else None,
            at,
            edited_at,
            deleted_at,
            MESSAGE_SOURCE,
        )
        at = at + timedelta(seconds=rng.uniform(*MESSAGE_GAP_SECONDS))


def message_rows(rng, cases):
    seen = set()
    for case in cases:
        for channel_id, thread_ts, kind, _, added_by in case.threads:
            if (channel_id, thread_ts) in seen:
                continue
            seen.add((channel_id, thread_ts))
            yield from thread_messages(rng, case, channel_id, thread_ts, kind, added_by)


def assignee_rows(cases, ids):
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None or case.claimed_by is None:
            continue
        yield (case_id, case.claimed_by, case.claimed_at, case.claimed_by)


def profiles_for(rng, members, as_of):
    shapes = {}
    for member in members:
        given = rng.choice(GIVEN_NAMES)
        family = rng.choice(FAMILY_NAMES)
        handle = f"{given}.{family[0]}" if rng.random() < 0.6 else f"{given}{rng.randrange(2, 99)}"
        tz, offset = rng.choice(TIMEZONES)
        shapes[member.user_id] = {
            "given": given,
            "family": family,
            "handle": handle,
            "display": "" if rng.random() < NO_DISPLAY_NAME_SHARE else handle,
            "pronouns": rng.choice(PRONOUN_POOL),
            "title": rng.choice(TITLES) if rng.random() < CUSTOM_TITLE_SHARE else "",
            "tz": tz,
            "tz_offset": offset,
            "hash": f"{rng.randrange(16**12):012x}",
            "updated_at": as_of - timedelta(days=rng.randrange(1, 400)),
        }
    return shapes


def member_rows(profiles, members):
    for member in members:
        shape = profiles[member.user_id]
        yield (
            member.user_id,
            shape["handle"],
            shape["display"],
            shape["title"],
            shape["pronouns"],
            f"https://avatars.{SEED_EMAIL_DOMAIN}/{shape['hash']}_192.jpg",
            shape["hash"],
            shape["tz"],
            shape["tz_offset"],
            SEED_ENTERPRISE,
            [SEED_TEAM],
            member.is_bot,
            member.deactivated_at is not None,
            member.is_admin,
            False,
            member.is_restricted,
            member.is_ultra_restricted,
            shape["updated_at"],
        )


def identity_rows(profiles, members):
    for member in members:
        shape = profiles[member.user_id]
        yield (
            member.user_id,
            f"{shape['given'].capitalize()} {shape['family'].capitalize()}",
            shape["given"].capitalize(),
            shape["family"].capitalize(),
            f"{shape['handle']}@{SEED_EMAIL_DOMAIN}",
        )


def participant_rows(cases, ids):
    for case in cases:
        case_id = ids.get(case.external_ref)
        if case_id is None:
            continue
        if case.subject_user_id:
            yield (case_id, case.subject_user_id, "subject", None)
        for user_id, role, detail in case.participants:
            yield (case_id, user_id, role, detail)


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
                report.closed_by,
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
        None, {"opened_by": case.opened_by, "source_app": "fire_engine"},
        "fire_engine", f"{request}:opened",
    )
    if case.subject_user_id:
        yield audit_entry(
            case.opened_at, case.opened_by, "participant", case_id, "attached",
            None,
            {"case_id": case_id, "user_id": case.subject_user_id, "role": "subject"},
            "fire_engine", f"{request}:subject",
        )
    if case.claimed_at:
        yield audit_entry(
            case.claimed_at, case.claimed_by, "assignee", case_id, "claimed",
            None,
            {
                "case_id": case_id,
                "user_id": case.claimed_by,
                "assigned_by": case.claimed_by,
            },
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


@dataclass
class SeedDecision:
    title: str
    statement: str
    category_key: str | None
    reasons: list
    state: str
    proposed_by: str
    proposed_at: datetime
    settled_by: str | None = None
    settled_at: datetime | None = None
    retired_by: str | None = None
    retired_at: datetime | None = None
    replaces: str | None = None
    threads: list = field(default_factory=list)

    @property
    def live_from(self):
        return self.settled_at or self.proposed_at


def build_decisions(rng, members, cases, as_of):
    crew = firefighters(members)
    if not crew:
        return []

    horizon = datetime.combine(as_of, time(23, 59), tzinfo=timezone.utc)
    resolved = [case for case in cases if case.resolved_at]
    built = []

    for entry in DECISION_LIBRARY:
        proposed_at = horizon - timedelta(days=entry["age_days"], hours=rng.uniform(0, 12))
        writer = rng.choice(crew)
        decision = SeedDecision(
            title=entry["title"],
            statement=entry["statement"],
            category_key=entry["category_key"],
            reasons=list(entry["reasons"]),
            state=entry["state"],
            proposed_by=writer,
            proposed_at=proposed_at,
            replaces=entry.get("replaces"),
        )
        if entry["state"] != "proposed":
            decision.settled_by = rng.choice(crew)
            decision.settled_at = proposed_at + timedelta(days=rng.uniform(*DECISION_SETTLE_DAYS))
        attach_decision_threads(rng, decision, crew, resolved)
        built.append(decision)

    retire_replaced(built)
    return built


def attach_decision_threads(rng, decision, crew, resolved):
    added_by = decision.proposed_by
    decision.threads.append((
        FD_CHANNEL,
        slack_ts(rng, decision.proposed_at),
        DECISION_THREAD_REASONS["first"],
        INTERNAL,
        added_by,
        decision.proposed_at,
    ))

    if rng.random() < DECISION_SECOND_INTERNAL_SHARE:
        later = decision.live_from + timedelta(days=rng.uniform(7.0, 30.0))
        decision.threads.append((
            FD_CHANNEL,
            slack_ts(rng, later),
            DECISION_THREAD_REASONS["second"],
            INTERNAL,
            rng.choice(crew),
            later,
        ))

    earlier = [case for case in resolved if case.opened_at <= decision.proposed_at]
    if earlier and rng.random() < DECISION_REFERENCE_SHARE:
        case = rng.choice(earlier[-40:])
        channel_id, thread_ts = case.threads[0][0], case.threads[0][1]
        decision.threads.append((
            channel_id,
            thread_ts,
            DECISION_THREAD_REASONS["reference"],
            REFERENCE,
            added_by,
            decision.proposed_at,
        ))


def retire_replaced(decisions):
    by_title = {decision.title: decision for decision in decisions}
    for decision in decisions:
        if decision.replaces is None:
            continue
        old = by_title.get(decision.replaces)
        if old is None:
            continue
        old.retired_by = decision.settled_by
        old.retired_at = decision.settled_at


def without_titles(decisions, taken):
    lowered = {title.lower() for title in taken}
    kept = [one for one in decisions if one.title.lower() not in lowered]
    gone = {one.title for one in decisions} - {one.title for one in kept}

    for decision in kept:
        if decision.replaces in gone:
            decision.replaces = None

    replaced = {one.replaces for one in kept if one.replaces}
    for decision in kept:
        if decision.state == "superseded" and decision.title not in replaced:
            decision.state = "settled"
            decision.retired_by = decision.retired_at = None

    return kept


def decision_rows(decisions):
    for decision in decisions:
        yield (
            decision.title,
            decision.statement,
            decision.category_key,
            decision.reasons,
            decision.state,
            decision.proposed_by,
            decision.proposed_at,
            decision.settled_by,
            decision.settled_at,
            decision.retired_by,
            decision.retired_at,
            decision.proposed_at,
            decision.retired_at or decision.settled_at or decision.proposed_at,
        )


def replacement_pairs(decisions):
    for decision in decisions:
        if decision.replaces:
            yield decision.replaces, decision.title


def decision_thread_rows(decisions, ids):
    for decision in decisions:
        decision_id = ids.get(decision.title)
        if decision_id is None:
            continue
        for channel_id, thread_ts, why, kind, added_by, added_at in decision.threads:
            yield (decision_id, channel_id, thread_ts, why, kind, added_by, added_at)


def decision_follows(rng, cases, decisions):
    taken = set()
    follows = []

    for decision in sorted(decisions, key=lambda one: one.live_from, reverse=True):
        behind = decision.state == "proposed"
        pool = [
            case for case in cases
            if case.external_ref not in taken and case.resolved_at
            and (case.resolved_at <= decision.proposed_at if behind
                 else case.resolved_at >= decision.live_from)
        ]
        if not pool:
            continue

        if behind:
            wanted = min(rng.randint(*DECISION_BEHIND_PROPOSAL), len(pool))
            pool = pool[-12:]
        else:
            wanted = round(len(pool) * DECISION_FOLLOW_SHARE * rng.uniform(0.4, 1.0))
        for case in rng.sample(pool, min(wanted, len(pool))):
            taken.add(case.external_ref)
            follows.append((
                case.external_ref,
                decision.title,
                case.resolved_at,
                case.claimed_by or case.opened_by,
            ))

    return follows


def decision_audit_rows(decisions, ids):
    for decision in decisions:
        decision_id = ids.get(decision.title)
        if decision_id is None:
            continue
        request = f"{SEED_REF_PREFIX}audit:decision:{decision_id}"
        yield audit_entry(
            decision.proposed_at, decision.proposed_by, "decision", decision_id, "proposed",
            None, {"title": decision.title, "state": "proposed"},
            "fire_engine", f"{request}:proposed",
        )
        if decision.settled_at:
            yield audit_entry(
                decision.settled_at, decision.settled_by, "decision", decision_id, "settled",
                {"state": "proposed"}, {"state": "settled"},
                "fire_engine", f"{request}:settled",
            )
        if decision.retired_at:
            yield audit_entry(
                decision.retired_at, decision.retired_by, "decision", decision_id, "superseded",
                {"state": "settled"}, {"state": "superseded"},
                "fire_engine", f"{request}:superseded",
            )


def follow_audit_rows(follows, case_ids, decision_ids):
    for external_ref, title, at, by in follows:
        case_id = case_ids.get(external_ref)
        decision_id = decision_ids.get(title)
        if case_id is None or decision_id is None:
            continue
        yield audit_entry(
            at, by, "case", case_id, "followed",
            {"followed_decision_id": None}, {"followed_decision_id": decision_id},
            "fire_engine", f"{SEED_REF_PREFIX}audit:case:{case_id}:followed",
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
