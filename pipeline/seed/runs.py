import json
from datetime import datetime, time, timedelta, timezone

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
    ("autojoin", 6, 13_000),
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


def dead_letter_rows(rng, as_of, count=40, hostile=False):
    for _ in range(count):
        source, base = DEAD_LETTER_REASONS[rng.randrange(len(DEAD_LETTER_REASONS))]
        seen = as_of - timedelta(days=rng.randrange(RUN_HISTORY), seconds=rng.randrange(86400))
        payload = {"user_id": f"USEED{rng.randrange(200_000):07d}", "keys": ["date", "user_id"]}
        yield (source, json.dumps(payload), hostile_module.reason(rng, base, hostile), seen)


def slack_event_rows(rng, members, as_of, count=25):
    joined = [m for m in members if (as_of - m.cohort_at).days < RUN_HISTORY]
    for member in joined[:count]:
        payload = {
            "type": "team_join",
            "user": {"id": member.user_id, "team_id": "TSEED0001"},
            "event_ts": f"{int(midnight(member.cohort_at, 9).timestamp())}.000100",
        }
        yield ("team_join", json.dumps(payload), midnight(member.cohort_at, 9))
