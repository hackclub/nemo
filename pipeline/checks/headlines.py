import argparse
import sys
from datetime import date, datetime, timezone

from dotenv import load_dotenv

import os

import psycopg

from lib.db import credentials
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient

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
    ours = one(conn, "select count(*) from analytics.dim_member where is_live and is_claimed")
    theirs = one(conn, "select total_claimed_count from analytics.mart_team_stats_daily "
                       "order by ds desc limit 1")
    return "dim_member.is_claimed, live members", "cross", "team.stats total_claimed_count", ours, theirs


SLACK_CHECKS = {
    "check_members_against_slack",
    "check_claimed_against_slack",
    "check_channel_members_against_slack",
    "check_channel_count_against_slack",
    "check_top_poster_against_slack",
}

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
]


KNOWN = {
    "mart_team_stats_daily.total_members_count": (
        0.10, "Slack counts everyone in the org today; dim_member holds the members we have walked"
    ),
}


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
    with connect_reader() as conn:
        for check in CHECKS:
            if only and only not in check.__name__:
                continue
            if cross_only and check.__name__ in SLACK_CHECKS:
                skipped += 1
                continue
            try:
                name, kind, source, ours, theirs = check(conn, client)
            except Exception as exc:
                conn.rollback()
                results.append((check.__name__, "error", str(exc).splitlines()[0][:70],
                                None, None, "error", None))
                continue
            state, delta = verdict(name, ours, theirs, tolerance)
            results.append((name, kind, source, ours, theirs, state, delta))

    width = max(len(r[0]) for r in results)
    print(f"{'headline':<{width}}  {'kind':<6}{'ours':>14}{'second source':>16}{'delta':>9}  state")
    print("-" * (width + 52))
    bad = 0
    for name, kind, source, ours, theirs, state, delta in results:
        if state not in ("ok", "known"):
            bad += 1
        d = "" if delta is None else f"{delta * 100:+.2f}%"
        o = "n/a" if ours is None else f"{int(ours):,}"
        t = "n/a" if theirs is None else f"{int(theirs):,}"
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
