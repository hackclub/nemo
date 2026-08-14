import argparse
import json
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, connect_admin
from seed.generate import Sampler
from seed.profile import ENV_FILE, PROFILE_FILE, capture

SHAPE_CHECKS = [
    ("members.rates.claimed", 0.05),
    ("members.rates.invite_pending", 0.05),
    ("members.rates.is_bot", 0.03),
    ("members.rates.is_admin", 0.03),
    ("members.rates.is_restricted", 0.03),
    ("members.rates.is_deleted", 0.05),
    ("messaging.ever_posted_rate", 0.08),
    ("replies.human_share", 0.10),
    ("replies.bot_only_share", 0.06),
    ("replies.no_reply_share", 0.10),
    ("replies.bot_first_share", 0.10),
    ("channels.archived_rate", 0.03),
]

QUANTILE_CHECKS = [
    ("replies.latency_seconds", 0.5, 1.5),
    ("replies.latency_seconds", 0.9, 1.5),
    ("channels.total_members", 0.5, 1.5),
    ("activity.messages_per_active_day", 0.9, 2.5),
    ("activity.messages_per_active_day", 0.99, 2.5),
    ("messaging.join_to_first_post_hours", 0.5, 3.0),
]

MIN_QUANTILE_SAMPLE = 500
TAIL_SAMPLES_PER_TAIL = 50

KNOWN_GAPS = []

MART_CHECKS = [
    ("mart_onboarding_funnel", "retained_day_30"),
    ("mart_onboarding_funnel", "retained_day_90"),
    ("mart_onboarding_recurrence_funnel", "returned_next_day"),
    ("mart_response_rate", "answered_by_member"),
    ("mart_response_rate", "median_member_latency_seconds"),
    ("mart_fast_reply_vs_retention", "retained_day_30_rate"),
    ("mart_fast_reply_vs_retention", "retained_day_90_rate"),
    ("mart_channel_onboarding_scorecard", "retained_90_share"),
    ("mart_activity_distribution", "members"),
    ("mart_growth", "claim_rate_30d"),
    ("mart_monthly_cohorts", "median_days_to_first_post"),
    ("mart_account_type", "members"),
    ("mart_team_stats_daily", "active_users_28d"),
    ("mart_team_stats_monthly", "mean_daily_active"),
    ("mart_top_posters", "messages_posted"),
    ("mart_channel_activity", "messages_posted"),
    ("mart_channel_range", "members_who_posted"),
]

CONSISTENCY_CHECKS = [
    (
        "member and channel day messages agree",
        "select (select coalesce(sum(messages_posted), 0) from raw.member_activity_snapshot "
        "where window_start = window_end) "
        "- (select coalesce(sum(messages_posted), 0) from raw.channel_activity_snapshot "
        "where window_start = window_end)",
    ),
    (
        "team stats messages agree with member days",
        "select (select coalesce(sum(messages_count_1d), 0) from raw.team_stats_snapshot) "
        "- (select coalesce(sum(messages_posted), 0) from raw.member_activity_snapshot "
        "where window_start = window_end)",
    ),
    (
        "every first poster has a history row",
        "select count(*) from raw.member_first_reply r "
        "left join raw.member_message_history h on h.user_id = r.user_id "
        "where h.user_id is null",
    ),
    (
        "every stored thread has exactly one root",
        "select count(*) from ("
        "select channel_id, thread_ts from fd.thread_messages "
        "group by channel_id, thread_ts having count(*) filter (where is_root) <> 1) t",
    ),
    (
        "every message belongs to a thread on a case",
        "select count(*) from fd.thread_messages m "
        "left join fd.case_threads t on t.channel_id = m.channel_id "
        "and t.thread_ts = m.thread_ts where t.case_id is null",
    ),
    (
        "a message deleted in slack keeps what it said",
        "select count(*) from fd.thread_messages "
        "where deleted_at is not null and body is null",
    ),
    (
        "every decision that is not a proposal says who settled it",
        "select count(*) from fd.decisions "
        "where state <> 'proposed' and (settled_by is null or settled_at is null)",
    ),
    (
        "every retired decision points at what replaced it",
        "select count(*) from fd.decisions "
        "where state = 'superseded' and replaced_by_id is null",
    ),
    (
        "no case follows a rule that was not in force when it was resolved",
        "select count(*) from fd.cases c join fd.decisions d "
        "on d.id = c.followed_decision_id "
        "where d.state <> 'proposed' and c.resolved_at < d.settled_at",
    ),
    (
        "no case sits behind a proposal written before the case was resolved",
        "select count(*) from fd.cases c join fd.decisions d "
        "on d.id = c.followed_decision_id "
        "where d.state = 'proposed' and c.resolved_at > d.proposed_at",
    ),
    (
        "every followed decision is recorded in the audit",
        "select count(*) from fd.cases c where c.followed_decision_id is not null "
        "and not exists (select 1 from fd.audit a where a.entity_type = 'case' "
        "and a.entity_id = c.id and a.verb = 'followed')",
    ),
    (
        "no day ledger gap inside the covered span",
        "select (max(ds) - min(ds) + 1) - count(*) from raw.analytics_day where source like 'seed_%member_day'",
    ),
]


def dig(node, path):
    for key in path.split("."):
        node = node[key]
    return node


def compare_shape(reference, seeded):
    for path, tolerance in SHAPE_CHECKS:
        want, got = dig(reference, path), dig(seeded, path)
        yield path, got, want, abs(got - want) <= tolerance, f"+-{tolerance}"


def compare_quantiles(reference, seeded):
    for path, point, factor in QUANTILE_CHECKS:
        block = dig(seeded, path)
        want = Sampler(dig(reference, path))(point)
        got = Sampler(block)(point)
        label = f"{path} p{int(point * 100)}"
        needed = max(MIN_QUANTILE_SAMPLE, round(TAIL_SAMPLES_PER_TAIL / (1 - point)))
        if block.get("n", 0) < needed:
            yield label, got, want, None, f"skipped, {block.get('n', 0)} rows, needs {needed}"
            continue
        if want <= 0:
            ok = got <= 1
        else:
            ok = (1 / factor) <= (got / max(got and want, 1e-9)) <= factor
        yield label, got, want, ok, f"within {factor}x"


def check_marts(admin):
    for table, column in MART_CHECKS:
        count = admin.execute(
            f"SELECT count(*) FROM analytics.{table} WHERE {column} IS NOT NULL"
        ).fetchone()[0]
        yield f"{table}.{column}", count, "> 0", count > 0, "at least one row"


def check_consistency(conn):
    for label, sql in CONSISTENCY_CHECKS:
        delta = conn.execute(sql).fetchone()[0] or 0
        yield label, delta, 0, delta == 0, "exactly 0"


def report(rows):
    failures = 0
    for label, got, want, ok, rule in rows:
        mark = "skip" if ok is None else ("ok  " if ok else "FAIL")
        failures += 1 if ok is False else 0
        shown = f"{got:.4g}" if isinstance(got, float) else got
        target = f"{want:.4g}" if isinstance(want, float) else want
        print(f"  {mark} {label:52} {shown!s:>12}  vs {target!s:>12}  ({rule})")
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(prog="seed.verify")
    parser.add_argument("--profile", type=Path, default=PROFILE_FILE)
    args = parser.parse_args(argv)
    load_dotenv(ENV_FILE)
    reference = json.loads(args.profile.read_text())

    with connect() as conn:
        conn.read_only = True
        mode = conn.execute("SELECT mode FROM raw.deployment").fetchone()[0]
        if mode != "seeded":
            print(f"seed.verify: this database is {mode}, not seeded. nothing to verify")
            raise SystemExit(2)
        seeded = capture(conn)
        print("shape against the captured profile")
        failures = report(compare_shape(reference, seeded))
        failures += report(compare_quantiles(reference, seeded))
        print("cross-table consistency")
        failures += report(check_consistency(conn))

    with connect_admin() as admin:
        admin.read_only = True
        print("marts populated")
        failures += report(check_marts(admin))
        print("known gaps, reported but not counted")
        for table, column, why in KNOWN_GAPS:
            count = admin.execute(
                f"SELECT count(*) FROM analytics.{table} WHERE {column} IS NOT NULL"
            ).fetchone()[0]
            state = "now populated, retire this entry" if count else "still empty"
            print(f"  gap  {table}.{column:28} {state}: {why}")

    print(f"seed.verify: {failures} failing check(s)")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
