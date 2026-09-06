import json
from datetime import date, datetime, time, timedelta, timezone

from seed import hostile as hostile_module

PARENT_SOURCE = "nightly_sync"
RUN_HISTORY = 14

STAGE_SOURCES = [
    ("team_stats", 4, 40),
    ("top_posters", 3, 150),
    ("admin_analytics_api:member", 90, 120_000),
    ("admin_analytics_api:public_channel", 70, 40_000),
    ("admin_analytics_member_range", 120, 215_000),
    ("admin_analytics_channel_range", 45, 13_000),
    ("users_list", 30, 215_000),
    ("channel_roster", 6, 13_000),
    ("channel_info_names", 5, 60),
    ("member_history", 200, 900),
    ("first_reply", 150, 200),
    ("dbt", 25, 0),
]

DEAD_LETTER_REASONS = [
    ("first_reply", "thread head vanished before the walk reached it"),
    ("first_reply", "conversations.replies returned channel_not_found"),
    ("member_history", "search.messages paging repeated a page"),
    ("admin_analytics_api:member", "'date' missing from a member_activity record"),
    ("users_list", "member arrived without a team_id"),
]

STEP_OUTPUT = {
    "dbt": "Done. PASS=106 WARN=0 ERROR=0 SKIP=0 TOTAL=106",
    "first_reply": "first reply: {rows} walked, {rejected} rejected",
}


def midnight(day, hour=3, minute=0):
    return datetime.combine(day, time(hour, minute), tzinfo=timezone.utc)


def statuses(index, total):
    if index == 0:
        return "running"
    if index == 3:
        return "failed"
    if index == 7:
        return "partial"
    return "ok"


def runs(rng, as_of, history=RUN_HISTORY):
    for index in range(history):
        day = as_of - timedelta(days=index)
        status = statuses(index, history)
        started = midnight(day) + timedelta(seconds=rng.randrange(120))
        yield index, day, status, started


def parent_rows(rng, as_of, history=RUN_HISTORY):
    for index, _, status, started in runs(rng, as_of, history):
        total = sum(seconds for _, seconds, _ in STAGE_SOURCES)
        finished = None if status == "running" else started + timedelta(seconds=total)
        yield (PARENT_SOURCE, started, finished, status, None, None, None, None, None, None)


def child_rows(rng, as_of, parent_ids, history=RUN_HISTORY):
    total = len(STAGE_SOURCES)
    for index, _, status, started in runs(rng, as_of, history):
        parent_id = parent_ids[index]
        cursor = started
        reached = 4 if status == "running" else total
        for step, (source, seconds, rows) in enumerate(STAGE_SOURCES[:reached], start=1):
            spent = timedelta(seconds=int(seconds * rng.uniform(0.7, 1.4)))
            child_status = "ok"
            if status == "failed" and step == total:
                child_status = "failed"
            elif status == "partial" and source == "first_reply":
                child_status = "failed"
            elif status == "running" and step == reached:
                child_status = "running"
            counted = int(rows * rng.uniform(0.9, 1.1)) if rows else None
            yield (
                source,
                cursor,
                None if child_status == "running" else cursor + spent,
                child_status,
                counted,
                rng.randrange(3) if counted else None,
                counted,
                parent_id,
                step,
                total,
            )
            cursor += spent


def step_output_rows(rng, parent_ids, hostile=False):
    for parent_id in parent_ids:
        for step, (source, _, rows) in enumerate(STAGE_SOURCES, start=1):
            template = STEP_OUTPUT.get(source)
            if not template:
                continue
            output = template.format(rows=rows, rejected=rng.randrange(4))
            yield (
                parent_id,
                step,
                source,
                hostile_module.reason(rng, output, hostile),
            )


COVERAGE_COLUMNS = [
    "source_key", "slice_key", "slice_start", "slice_end", "state",
    "expected", "landed", "attempts", "claimed_at", "settled_at", "lease_until",
]

COVERAGE_DAYS = 60


def coverage_rows(rng, as_of):
    for offset in range(COVERAGE_DAYS):
        day = as_of - timedelta(days=offset)
        expected = 120_000 + rng.randrange(2_000)
        if offset == 0:
            yield ("member_days", day.isoformat(), day, day, "claimed", expected, 2000, 1,
                   midnight(day), None, midnight(day) + timedelta(hours=1))
            continue
        state = "short" if offset in (3, 17) else "complete"
        landed = expected - rng.randrange(20_000, 40_000) if state == "short" else expected
        yield ("member_days", day.isoformat(), day, day, state, expected, landed,
               2 if state == "short" else 1, midnight(day), midnight(day, 3, 40), None)
        yield ("channel_days", day.isoformat(), day, day, "complete", 40_000, 40_000, 1,
               midnight(day), midnight(day, 3, 10), None)
    first = (as_of - timedelta(days=COVERAGE_DAYS)).replace(day=1)
    cursor = first
    while cursor <= as_of.replace(day=1):
        last = date(cursor.year + cursor.month // 12, cursor.month % 12 + 1, 1) - timedelta(days=1)
        whole = last < as_of
        yield ("channel_month", cursor.strftime("%Y-%m"), cursor, min(last, as_of),
               "complete" if whole else "short", 13_308, 13_306 if whole else 9_800, 1,
               midnight(cursor), midnight(cursor, 4), None)
        cursor = last + timedelta(days=1)
    for offset in range(3):
        stop = as_of - timedelta(days=offset)
        start = stop - timedelta(days=364)
        yield ("member_range", f"{start}..{stop}", start, stop,
               "complete" if offset == 0 else "superseded", 216_540, 216_540, 1,
               midnight(stop), midnight(stop, 5), None)


def dead_letter_rows(rng, as_of, count=40, hostile=False):
    for _ in range(count):
        source, base = DEAD_LETTER_REASONS[rng.randrange(len(DEAD_LETTER_REASONS))]
        seen = as_of - timedelta(days=rng.randrange(RUN_HISTORY), seconds=rng.randrange(86400))
        payload = {"user_id": f"USEED{rng.randrange(200_000):07d}", "keys": ["date", "user_id"]}
        yield (source, json.dumps(payload), hostile_module.reason(rng, base, hostile), seen)


