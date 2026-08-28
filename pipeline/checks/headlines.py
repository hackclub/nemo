import argparse
import sys
from datetime import date, datetime, timezone

from dotenv import load_dotenv

import os

import psycopg

from lib import sources
from lib.db import connect, credentials
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.settings import PERIOD

TOLERANCE = 0.01


def connect_reader():
    user, password = credentials("RAILS")
    return psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        dbname=os.environ["POSTGRES_DB"],
        user=user,
        password=password,
    )


STAMPS = ("updated_at", "created_at", "searched_at", "seen_at")


def columns_of(conn, table):
    schema, name = table.split(".", 1)
    with conn.cursor() as cur:
        cur.execute("""select column_name from information_schema.columns
                       where table_schema = %s and table_name = %s""", (schema, name))
        return {r[0] for r in cur.fetchall()}


def newest_stamp(conn, table, wrote_as):
    schema, name = table.split(".", 1)
    have = columns_of(conn, table)
    column = next((c for c in STAMPS if c in have), None)
    if column is None:
        return None
    where, args = "", ()
    if "source" in have and wrote_as:
        where = " where source = any(%s)"
        args = (wrote_as,)
    with conn.cursor() as cur:
        cur.execute(f"select max({column}) from {schema}.{name}{where}", args)
        return cur.fetchone()[0]


def wrote_as(key):
    seen = []
    for name in sources.runs_as(key):
        head = name.split(":", 1)[0]
        if head not in seen:
            seen.append(head)
    return seen


def last_produced(conn, key):
    newest = None
    for table in sources.says(key, "writes"):
        if not table.startswith("raw.") or table.count(".") != 1:
            continue
        try:
            stamp = newest_stamp(conn, table, wrote_as(key))
        except Exception:
            conn.rollback()
            continue
        if stamp and (newest is None or stamp > newest):
            newest = stamp
    return newest


def last_ok_run(conn, key):
    with conn.cursor() as cur:
        cur.execute("""select max(finished_at) from raw.ingest_run
                       where status = 'ok' and source = any(%s)""", (list(sources.runs_as(key)),))
        return cur.fetchone()[0]


def check_every_source_is_fresh(pipe_conn):
    now = datetime.now(timezone.utc)
    rows = []
    for key in sources.KEYS:
        cadence = sources.says(key, "cadence")
        window = PERIOD.get(cadence)
        if window is None:
            continue
        produced = last_produced(pipe_conn, key)
        ran = last_ok_run(pipe_conn, key)
        seen = max([x for x in (produced, ran) if x], default=None)
        allowed = window.total_seconds() / 3600
        if seen is None:
            rows.append((f"{key}, hours since it last produced", "fresh",
                         f"{cadence}, and nothing on record", None, allowed))
            continue
        age = (now - seen).total_seconds() / 3600
        rows.append((f"{key}, hours since it last produced", "fresh",
                     f"{cadence}, so {allowed:.0f}h", round(age, 1), allowed))
    return rows


FULL_PLAN_SQL = """
select max(x.finished_at) from (
    select p.id, p.finished_at, max(c.step_total) as planned
    from raw.ingest_run p
    join raw.ingest_run c on c.parent_run_id = p.id
    where p.source = 'nightly_sync'
    group by p.id, p.finished_at
) x where x.planned >= %s
"""

LAST_PLAN_SQL = """
select coalesce(max(c.step_total), 0)
from raw.ingest_run p
left join raw.ingest_run c on c.parent_run_id = p.id
where p.id = (select max(id) from raw.ingest_run
              where source = 'nightly_sync' and parent_run_id is null)
"""


def check_the_nightly_ran_the_whole_plan(pipe_conn):
    total = len(sources.KEYS)
    now = datetime.now(timezone.utc)
    rows = []
    with pipe_conn.cursor() as cur:
        cur.execute(FULL_PLAN_SQL, (total,))
        newest = cur.fetchone()[0]
        cur.execute(LAST_PLAN_SQL)
        planned = cur.fetchone()[0]
    rows.append(("the last nightly, stages planned", "plan",
                 f"all {total} of them", planned, total))
    if newest is None:
        rows.append(("hours since a nightly ran every stage", "fresh",
                     "daily, and no full plan is on record", None, 20.0))
    else:
        rows.append(("hours since a nightly ran every stage", "fresh",
                     "daily, so 20h", round((now - newest).total_seconds() / 3600, 1), 20.0))
    return rows


def utc_date(value):
    if not value:
        return None
    return datetime.fromtimestamp(int(value), tz=timezone.utc).date()


def one(conn, sql, args=None):
    with conn.cursor() as cur:
        cur.execute(sql, args or ())
        row = cur.fetchone()
    return None if row is None else row[0]


def team_stats_today(client):
    end = one_date(client)
    resp = client.call(
        "team.stats.timeSeries",
        {"start_date": end.isoformat(), "end_date": end.isoformat()},
    )
    rows = resp.get("stats") or resp.get("data") or []
    return rows[-1] if rows else {}


def one_date(client):
    avail = client.call("admin.analytics.getAvailableDateRange", {"type": "member"})
    return date.fromisoformat(avail["end_date"])


def member_page(client, count=500):
    avail = client.call("admin.analytics.getAvailableDateRange", {"type": "member"})
    resp = client.call(
        "admin.analytics.getMemberAnalytics",
        {
            "start_date": avail["start_date"],
            "end_date": avail["end_date"],
            "sort_column": "messages_posted",
            "sort_direction": "desc",
            "count": count,
        },
    )
    return resp.get("member_activity") or [], resp.get("num_found")


def channel_page(client, count=500):
    end = one_date(client)
    resp = client.call(
        "admin.analytics.getChannelAnalytics",
        {
            "start_date": end.isoformat(),
            "end_date": end.isoformat(),
            "privacy": "public",
            "sort_column": "messages_count",
            "sort_direction": "desc",
            "count": count,
        },
    )
    return resp.get("channel_analytics") or [], resp.get("num_found")


def check_members_against_slack(conn, client):
    ours = one(conn, "select total_members_count from analytics.mart_team_stats_daily "
                     "order by ds desc limit 1")
    stats = team_stats_today(client)
    theirs = stats.get("total_members_count") or stats.get("total_members")
    return "mart_team_stats_daily.total_members_count", "slack", "team.stats.timeSeries", ours, theirs


def check_members_against_the_dimension(conn, client):
    ours = one(conn, "select total_members_count from analytics.mart_team_stats_daily "
                     "order by ds desc limit 1")
    theirs = one(conn, "select count(*) from analytics.dim_member where is_live")
    return "mart_team_stats_daily.total_members_count", "cross", "dim_member.is_live", ours, theirs


def check_account_types_sum_to_the_workspace(conn, client):
    ours = one(conn, "select sum(members) from analytics.mart_account_type")
    theirs = one(conn, "select count(*) from analytics.dim_member "
                       "where not is_bot and not is_deleted")
    return "mart_account_type.members, summed", "cross", "dim_member, live and not a bot", ours, theirs


def check_growth_cohorts_against_the_dimension(conn, client):
    ours = one(conn, "select sum(created_members) from analytics.mart_growth")
    theirs = one(conn, """
        select count(*) from analytics.dim_member
        where cohort_at >= (select min(month) from analytics.mart_growth)
          and cohort_at <  (select max(month) + interval '1 month' from analytics.mart_growth)
          and not is_bot""")
    return "mart_growth.created_members, summed", "cross", "dim_member.cohort_at", ours, theirs


def check_monthly_stats_roll_up_the_daily(conn, client):
    ours = one(conn, """
        select channel_messages from analytics.mart_team_stats_monthly
        where is_complete order by month desc limit 1""")
    theirs = one(conn, """
        select sum(d.channel_messages_1d) from analytics.mart_team_stats_daily d
        where date_trunc('month', d.ds) = (
            select month from analytics.mart_team_stats_monthly
            where is_complete order by month desc limit 1)""")
    return "mart_team_stats_monthly.channel_messages", "cross", "the daily mart, summed", ours, theirs


def check_the_two_channel_sources_stay_together(conn, client):
    lag = one(conn, """
        select (select max(window_end) from analytics.mart_channel_range)
             - (select max(window_start) from analytics.mart_channel_activity)""")
    return ("channel daily pull, days behind the walk", "cross",
            "0 days if both ran last night", lag, 0)


def check_channel_members_against_slack(conn, client):
    rows, _ = channel_page(client, count=200)
    if not rows:
        return "mart_channel_range.total_members", "slack", "getChannelAnalytics", None, None
    top = rows[0]
    ours = one(conn, "select total_members from analytics.mart_channel_range where channel_id = %s",
               (top["channel_id"],))
    return (f"mart_channel_range.total_members #{top.get('name')}", "slack",
            "getChannelAnalytics", ours, top.get("total_members_count"))


def check_channel_count_against_slack(conn, client):
    _, found = channel_page(client, count=1)
    ours = one(conn, "select count(*) from analytics.mart_channel_range")
    return "mart_channel_range, row count", "slack", "getChannelAnalytics num_found", ours, found


def check_top_poster_against_slack(conn, client):
    row = None
    with conn.cursor() as cur:
        cur.execute("""select window_start, window_end, messages_posted
                       from analytics.mart_top_posters where rank = 1
                       order by month desc limit 1""")
        row = cur.fetchone()
    if row is None:
        return "mart_top_posters.messages_posted", "slack", "getMemberAnalytics", None, None
    start, end, ours = row
    resp = client.call("admin.analytics.getMemberAnalytics", {
        "start_date": start.isoformat(), "end_date": end.isoformat(),
        "sort_column": "messages_posted", "sort_direction": "desc", "count": 1})
    recs = resp.get("member_activity") or []
    theirs = recs[0].get("messages_posted") if recs else None
    return (f"mart_top_posters, rank 1 for {start:%b %Y}", "slack",
            "getMemberAnalytics over the same month", ours, theirs)


def check_distribution_population(conn, client):
    ours = one(conn, "select max(workspace_members) from analytics.mart_activity_distribution")
    theirs = one(conn, "select count(*) from analytics.dim_member "
                       "where not is_bot and not invite_pending")
    return "mart_activity_distribution.workspace_members", "cross", "dim_member, walkable", ours, theirs


RETENTION_COVERAGE_SQL = """
select count(distinct first_post_on) as dates,
       count(distinct first_post_on) filter (where day_30_covered) as day_30,
       count(distinct first_post_on) filter (where day_90_covered) as day_90,
       count(distinct first_post_on) filter (where visits_knowable) as visits
from analytics.fct_member_retention
"""

MEMBER_DAYS_SQL = "select window_start from analytics.fct_member_activity group by 1 order by 1"

VISITS_NEED = 15


def longest_run(days):
    best = run = 0
    for i, day in enumerate(days):
        run = run + 1 if i and (day - days[i - 1]).days == 1 else 1
        best = max(best, run)
    return best


def check_retention_coverage(conn, client):
    with conn.cursor() as cur:
        cur.execute(RETENTION_COVERAGE_SQL)
        dates, day_30, day_90, visits = cur.fetchone()
        cur.execute(MEMBER_DAYS_SQL)
        days = [r[0] for r in cur.fetchall()]
    return [
        ("first-post dates with a day-30 observation", "cover",
         "one member-day inside the 8 days at +23..+30", day_30, dates),
        ("first-post dates with a day-90 observation", "cover",
         "one member-day inside the 8 days at +83..+90", day_90, dates),
        ("first-post dates where visits are knowable", "cover",
         f"{VISITS_NEED} consecutive member-days from the first post", visits, dates),
        ("longest unbroken run of member-days", "cover",
         f"{VISITS_NEED}, which is what the visit steps need", longest_run(days), VISITS_NEED),
    ]


def check_response_rate_totals(conn, client):
    ours = one(conn, """
        select sum(first_posts_checked) - sum(unanswered)
        from analytics.mart_response_rate""")
    theirs = one(conn, """
        select count(*) from analytics.fct_first_reply
        where date_trunc('month', post_at) in
              (select post_month from analytics.mart_response_rate)""")
    return ("mart_response_rate, posts that drew a reply", "cross",
            "fct_first_reply rows", ours, theirs)


def check_claimed_against_slack(conn, client):
    ours = one(conn, "select total_claimed_count from analytics.mart_team_stats_daily "
                     "order by ds desc limit 1")
    stats = team_stats_today(client)
    theirs = stats.get("total_claimed_count")
    return "mart_team_stats_daily.total_claimed_count", "slack", "team.stats.timeSeries", ours, theirs


def check_our_claimed_flag_against_slack(conn, client):
    ours = one(conn, """
        select round(100.0 * count(*) filter (where is_claimed) / nullif(count(*), 0))
        from analytics.dim_member where is_live""")
    theirs = one(conn, """
        select round(100.0 * total_claimed_count / nullif(total_members_count, 0))
        from analytics.mart_team_stats_daily order by ds desc limit 1""")
    return "claim rate, percent", "cross", "team.stats claim rate", ours, theirs


SLACK_CHECKS = {
    "check_members_against_slack",
    "check_claimed_against_slack",
    "check_channel_members_against_slack",
    "check_channel_count_against_slack",
    "check_top_poster_against_slack",
}

PIPELINE_CHECKS = [check_every_source_is_fresh, check_the_nightly_ran_the_whole_plan]

CHECKS = [
    check_members_against_slack,
    check_claimed_against_slack,
    check_members_against_the_dimension,
    check_our_claimed_flag_against_slack,
    check_account_types_sum_to_the_workspace,
    check_growth_cohorts_against_the_dimension,
    check_monthly_stats_roll_up_the_daily,
    check_the_two_channel_sources_stay_together,
    check_channel_members_against_slack,
    check_channel_count_against_slack,
    check_top_poster_against_slack,
    check_distribution_population,
    check_response_rate_totals,
    check_retention_coverage,
]


KNOWN = {
    "claim rate, percent": (
        0.30, "our denominator is the live members we have walked, which excludes a large "
              "pool of never-claimed deactivated accounts that Slack still counts"
    ),
    "mart_team_stats_daily.total_members_count": (
        0.10, "Slack counts everyone in the org today; dim_member holds the members we have walked"
    ),
}


def stale_verdict(age, allowed):
    if age is None:
        return "no record", None
    if age <= allowed:
        return "ok", None
    return "stale", (age - allowed) / allowed


def verdict(name, ours, theirs, tolerance):
    if ours is None or theirs is None:
        return "no data", None
    ours, theirs = float(ours), float(theirs)
    if theirs == 0:
        return ("ok" if ours == 0 else "differs"), None
    delta = (ours - theirs) / theirs
    if abs(delta) <= tolerance:
        return "ok", delta
    bound = KNOWN.get(name)
    if bound and abs(delta) <= bound[0]:
        return "known", delta
    return "differs", delta


def run(only=None, tolerance=TOLERANCE, cross_only=False):
    load_dotenv(ENV_FILE)
    client = None if cross_only else ProxyClient()
    results = []
    skipped = 0
    with connect() as pipe:
        for check in PIPELINE_CHECKS:
            try:
                results.extend(check(pipe))
            except Exception as exc:
                pipe.rollback()
                results.append((check.__name__, "error", str(exc).splitlines()[0][:70],
                                None, None, "error", None))

    with connect_reader() as conn:
        for check in CHECKS:
            if only and only not in check.__name__:
                continue
            if cross_only and check.__name__ in SLACK_CHECKS:
                skipped += 1
                continue
            try:
                got = check(conn, client)
            except Exception as exc:
                conn.rollback()
                results.append((check.__name__, "error", str(exc).splitlines()[0][:70],
                                None, None, "error", None))
                continue
            for name, kind, source, ours, theirs in (got if isinstance(got, list) else [got]):
                state, delta = verdict(name, ours, theirs, tolerance)
                results.append((name, kind, source, ours, theirs, state, delta))

    graded = []
    for row in results:
        if len(row) == 5:
            name, kind, source, ours, theirs = row
            if kind in ("plan", "cover"):
                state, delta = verdict(name, ours, theirs, 0.0)
            else:
                state, delta = stale_verdict(ours, theirs)
            graded.append((name, kind, source, ours, theirs, state, delta))
        else:
            graded.append(row)
    results = graded

    width = max(len(r[0]) for r in results)
    print(f"{'headline':<{width}}  {'kind':<6}{'ours':>14}{'second source':>16}{'delta':>9}  state")
    print("-" * (width + 52))
    bad = 0
    for name, kind, source, ours, theirs, state, delta in results:
        if state not in ("ok", "known"):
            bad += 1
        d = "" if delta is None else f"{delta * 100:+.2f}%"
        o = "n/a" if ours is None else (f"{ours:,.1f}" if isinstance(ours, float) else f"{int(ours):,}")
        t = "n/a" if theirs is None else (f"{theirs:,.0f}" if isinstance(theirs, float) else f"{int(theirs):,}")
        print(f"{name:<{width}}  {kind:<6}{o:>14}{t:>16}{d:>9}  {state}")
        if state != "ok":
            note = KNOWN.get(name)
            print(f"{'':<{width}}  against {source}")
            if state == "known" and note:
                print(f"{'':<{width}}  known: {note[1]}")
    print()
    print(f"{len(results) - bad} of {len(results)} agree within {tolerance * 100:g}%"
          f" (known differences counted as agreeing)")
    if skipped:
        print(f"{skipped} check(s) that need Slack were skipped")
    return bad


def main():
    parser = argparse.ArgumentParser(description="check every headline against a second source")
    parser.add_argument("--only", help="substring of a check name")
    parser.add_argument("--tolerance", type=float, default=TOLERANCE)
    parser.add_argument("--cross-only", action="store_true",
                        help="skip the checks that call Slack, for a machine without credentials")
    args = parser.parse_args()
    sys.exit(1 if run(args.only, args.tolerance, args.cross_only) else 0)


if __name__ == "__main__":
    main()
