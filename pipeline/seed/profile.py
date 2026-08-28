import argparse
import json
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

PROFILE_FILE = Path(__file__).resolve().parent / "profile.json"

QUANTILES = [0.01, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 0.99]
SEASONALITY_DAYS = 180
TRANSITION_DAYS = 120


def quantiles(conn, expression, source, where="true"):
    row = conn.execute(
        f"SELECT count(*), percentile_cont(%s) WITHIN GROUP (ORDER BY {expression}) "
        f"FROM {source} WHERE {where} AND ({expression}) IS NOT NULL",
        (QUANTILES,),
    ).fetchone()
    if not row[0]:
        return {"n": 0, "p": QUANTILES, "v": []}
    return {"n": row[0], "p": QUANTILES, "v": [round(float(v), 4) for v in row[1]]}


def shares(conn, sql):
    return {str(key): round(float(share), 6) for key, share in conn.execute(sql).fetchall()}


def member_shape(conn):
    return {
        "count": conn.execute("SELECT count(*) FROM raw.member_dim").fetchone()[0],
        "cohort_sizes": [
            [month.isoformat(), count]
            for month, count in conn.execute(
                "SELECT date_trunc('month', account_created_verified)::date AS m, count(*) "
                "FROM raw.member_dim WHERE account_created_verified IS NOT NULL "
                "GROUP BY m ORDER BY m"
            ).fetchall()
        ],
        "rates": conn.execute(
            """
            SELECT
                avg((claimed_at IS NOT NULL)::int),
                avg(coalesce(invite_pending, false)::int),
                avg(coalesce(is_bot, false)::int),
                avg(coalesce(is_admin, false)::int),
                avg(coalesce(is_restricted, false)::int),
                avg(coalesce(is_ultra_restricted, false)::int),
                avg(coalesce(is_deleted, deactivated_at IS NOT NULL)::int),
                avg((is_invited_member IS TRUE)::int)
            FROM raw.member_dim
            """
        ).fetchone(),
        "claimed_at_source": shares(
            conn,
            "SELECT coalesce(claimed_at_source, 'none'), count(*)::numeric / sum(count(*)) OVER () "
            "FROM raw.member_dim WHERE claimed_at IS NOT NULL GROUP BY 1",
        ),
    }


def messaging_shape(conn):
    return {
        "total_messages": quantiles(conn, "total_messages", "raw.member_message_history"),
        "ever_posted_rate": float(
            conn.execute(
                "SELECT avg((total_messages > 0)::int) FROM raw.member_message_history"
            ).fetchone()[0]
            or 0
        ),
        "searched_rate": float(
            conn.execute(
                "SELECT count(*)::numeric / nullif((SELECT count(*) FROM raw.member_dim), 0) "
                "FROM raw.member_message_history"
            ).fetchone()[0]
            or 0
        ),
        "join_to_first_post_hours": quantiles(
            conn,
            "extract(epoch FROM h.first_post_ts - d.account_created_verified) / 3600",
            "raw.member_message_history h JOIN raw.member_dim d ON d.user_id = h.user_id",
            "h.first_post_ts IS NOT NULL AND d.account_created_verified IS NOT NULL "
            "AND h.first_post_ts >= d.account_created_verified",
        ),
    }


def reply_shape(conn):
    counts = conn.execute(
        """
        SELECT
            count(*),
            count(*) FILTER (WHERE replier_id IS NOT NULL),
            count(*) FILTER (WHERE replier_id IS NULL AND bot_replier_id IS NOT NULL),
            count(*) FILTER (WHERE replier_id IS NULL AND bot_replier_id IS NULL
                             AND coalesce(unreadable, false) IS FALSE),
            count(*) FILTER (WHERE coalesce(unreadable, false)),
            count(*) FILTER (WHERE bot_replier_id IS NOT NULL AND replier_id IS NOT NULL
                             AND bot_reply_ts < reply_ts)
        FROM raw.member_first_reply
        """
    ).fetchone()
    total = counts[0] or 1
    return {
        "n": counts[0],
        "human_share": round(counts[1] / total, 6),
        "bot_only_share": round(counts[2] / total, 6),
        "no_reply_share": round(counts[3] / total, 6),
        "unreadable_share": round(counts[4] / total, 6),
        "bot_first_share": round(counts[5] / total, 6),
        "latency_seconds": quantiles(conn, "latency_seconds", "raw.member_first_reply"),
        "bot_latency_seconds": quantiles(conn, "bot_latency_seconds", "raw.member_first_reply"),
    }


NEWEST_WINDOW = "source = 'admin_analytics_channel_range'"


def channel_shape(conn):
    return {
        "count": conn.execute("SELECT count(*) FROM raw.channel_dim").fetchone()[0],
        "total_members": quantiles(
            conn, "total_members", "raw.channel_activity_snapshot", NEWEST_WINDOW
        ),
        "guest_share": quantiles(
            conn,
            "guests::numeric / nullif(total_members, 0)",
            "raw.channel_activity_snapshot",
            f"{NEWEST_WINDOW} AND total_members > 0",
        ),
        "archived_rate": float(
            conn.execute(
                "SELECT avg(coalesce(archived, false)::int) FROM raw.channel_dim"
            ).fetchone()[0]
            or 0
        ),
        "visibility": shares(
            conn,
            "SELECT coalesce(visibility, 'unknown'), count(*)::numeric / sum(count(*)) OVER () "
            "FROM raw.channel_dim GROUP BY 1",
        ),
        "name_length": quantiles(conn, "length(name)", "raw.channel_dim", "name IS NOT NULL"),
    }


def activity_shape(conn):
    daily = "raw.member_activity_snapshot"
    is_daily = "window_start = window_end"
    covered = conn.execute(
        f"SELECT count(DISTINCT window_start) FROM {daily} WHERE {is_daily}"
    ).fetchone()[0]
    transitions = conn.execute(
        """
        WITH days AS (
            SELECT DISTINCT window_start AS ds FROM raw.member_activity_snapshot
            WHERE window_start = window_end
            ORDER BY ds DESC LIMIT %s
        ),
        active AS (
            SELECT a.user_id, a.window_start AS ds
            FROM raw.member_activity_snapshot a JOIN days d ON d.ds = a.window_start
            WHERE a.window_start = a.window_end AND coalesce(a.days_active, 0) > 0
        ),
        paired AS (
            SELECT
                a.user_id,
                a.ds,
                lag(a.ds) OVER (PARTITION BY a.user_id ORDER BY a.ds) AS prev_ds
            FROM active a
        )
        SELECT
            count(*) FILTER (WHERE prev_ds = ds - 1)::numeric / nullif(count(*), 0),
            avg(ds - prev_ds) FILTER (WHERE prev_ds IS NOT NULL),
            count(*) FILTER (WHERE prev_ds = ds - 1)
        FROM paired
        """,
        (TRANSITION_DAYS,),
    ).fetchone()
    adjacent = conn.execute(
        f"""
        WITH days AS (SELECT DISTINCT window_start AS ds FROM {daily} WHERE {is_daily})
        SELECT count(*) FROM days a JOIN days b ON b.ds = a.ds + 1
        """
    ).fetchone()[0]
    return {
        "covered_days": covered,
        "adjacent_day_pairs": adjacent,
        "transition_sample": transitions[2],
        "messages_per_active_day": quantiles(
            conn, "messages_posted", daily, f"{is_daily} AND coalesce(days_active, 0) > 0"
        ),
        "reactions_per_active_day": quantiles(
            conn, "reactions_added", daily, f"{is_daily} AND coalesce(days_active, 0) > 0"
        ),
        "active_days_per_member": quantiles(
            conn,
            "n",
            "(SELECT user_id, count(*) AS n FROM raw.member_activity_snapshot "
            "WHERE window_start = window_end AND coalesce(days_active, 0) > 0 "
            "GROUP BY user_id) counts",
        ),
        "stay_active_next_day": round(float(transitions[0] or 0), 6),
        "mean_gap_days": round(float(transitions[1] or 0), 4),
    }


def seasonality_shape(conn):
    return {
        "day_of_week": [
            [int(dow), round(float(factor), 6)]
            for dow, factor in conn.execute(
                """
                WITH recent AS (
                    SELECT ds, active_users_1d FROM raw.team_stats_snapshot
                    WHERE active_users_1d IS NOT NULL ORDER BY ds DESC LIMIT %s
                )
                SELECT extract(dow FROM ds), avg(active_users_1d) / (SELECT avg(active_users_1d) FROM recent)
                FROM recent GROUP BY 1 ORDER BY 1
                """,
                (SEASONALITY_DAYS,),
            ).fetchall()
        ],
        "month_of_year": [
            [int(month), round(float(factor), 6)]
            for month, factor in conn.execute(
                """
                SELECT extract(month FROM ds),
                       avg(active_users_1d) / (SELECT avg(active_users_1d) FROM raw.team_stats_snapshot
                                               WHERE active_users_1d IS NOT NULL)
                FROM raw.team_stats_snapshot WHERE active_users_1d IS NOT NULL
                GROUP BY 1 ORDER BY 1
                """
            ).fetchall()
        ],
        "active_users_1d": quantiles(conn, "active_users_1d", "raw.team_stats_snapshot"),
        "writers_over_active": quantiles(
            conn,
            "writers_count_1d::numeric / nullif(active_users_1d, 0)",
            "raw.team_stats_snapshot",
            "active_users_1d > 0",
        ),
    }


def capture(conn):
    members = member_shape(conn)
    rates = members.pop("rates")
    members["rates"] = {
        name: round(float(value or 0), 6)
        for name, value in zip(
            [
                "claimed",
                "invite_pending",
                "is_bot",
                "is_admin",
                "is_restricted",
                "is_ultra_restricted",
                "is_deleted",
                "is_invited_member",
            ],
            rates,
            strict=True,
        )
    }
    return {
        "captured_at": datetime.now().date().isoformat(),
        "quantiles": QUANTILES,
        "members": members,
        "messaging": messaging_shape(conn),
        "replies": reply_shape(conn),
        "channels": channel_shape(conn),
        "activity": activity_shape(conn),
        "seasonality": seasonality_shape(conn),
    }


def summarise(profile):
    lines = [
        f"captured {profile['captured_at']}",
        f"members {profile['members']['count']} across "
        f"{len(profile['members']['cohort_sizes'])} cohort months",
        f"claimed {profile['members']['rates']['claimed']:.1%}, "
        f"bots {profile['members']['rates']['is_bot']:.1%}, "
        f"deleted {profile['members']['rates']['is_deleted']:.1%}",
        f"ever posted {profile['messaging']['ever_posted_rate']:.1%}, "
        f"median lifetime messages {median(profile['messaging']['total_messages'])}",
        f"replies human {profile['replies']['human_share']:.1%}, "
        f"bot only {profile['replies']['bot_only_share']:.1%}, "
        f"none {profile['replies']['no_reply_share']:.1%}, "
        f"bot first {profile['replies']['bot_first_share']:.1%}",
        f"median human reply latency {median(profile['replies']['latency_seconds'])}s",
        f"channels {profile['channels']['count']}, "
        f"archived {profile['channels']['archived_rate']:.1%}, "
        f"median members {median(profile['channels']['total_members'])}",
        f"covered days {profile['activity']['covered_days']} "
        f"({profile['activity']['adjacent_day_pairs']} adjacent pairs), "
        f"stays active next day {profile['activity']['stay_active_next_day']:.1%} "
        f"over {profile['activity']['transition_sample']} observations",
    ]
    return "\n".join(lines)


def median(block):
    if not block["v"]:
        return None
    return block["v"][block["p"].index(0.5)]


def main(argv=None):
    parser = argparse.ArgumentParser(prog="seed.profile")
    parser.add_argument("--capture", action="store_true")
    parser.add_argument("--out", type=Path, default=PROFILE_FILE)
    args = parser.parse_args(argv)

    if not args.capture:
        print(summarise(json.loads(args.out.read_text())))
        return

    load_dotenv(ENV_FILE)
    with connect() as conn:
        conn.read_only = True
        profile = capture(conn)
    args.out.write_text(json.dumps(profile, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.out}")
    print(summarise(profile))


if __name__ == "__main__":
    main()
