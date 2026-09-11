from dotenv import load_dotenv
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

from lib import shards
from lib.db import connect
from lib.paths import ENV_FILE

SUBJECT = "shards"
PROBE_TIMEOUT = 20

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'shards', %s, %s, %s, %s, %s)
"""

WARN_ONLY = frozenset({"the pool is configured"})


def identify(token):
    client = WebClient(token=token, timeout=PROBE_TIMEOUT, retry_handlers=[])
    try:
        return dict(client.auth_test().data), None
    except SlackApiError as failure:
        response = getattr(failure, "response", None) or {}
        error = response.get("error") if hasattr(response, "get") else str(failure)
        return None, error or str(failure)


def survey(env=None):
    return [(index, identify(token)) for index, token in shards.discover(env)]


def the_pool_is_configured(_conn, found):
    if not found:
        return ("the pool is configured", "warn",
                f"no {shards.PREFIX}n set, replies stay on the proxy", "1 or more")
    return ("the pool is configured", "pass", f"{len(found)} token(s)", "1 or more")


def every_token_is_live(_conn, found):
    dead = [f"{shards.PREFIX}{index} ({error})" for index, (who, error) in found if who is None]
    if not found:
        return ("every token is live", "pass", "no token to probe", "0 dead")
    return ("every token is live", "pass" if not dead else "fail",
            f"{len(dead)} dead: {', '.join(dead)}" if dead else f"{len(found)} live", "0 dead")


def every_token_is_a_user_token(_conn, found):
    bots = [f"{shards.PREFIX}{index}" for index, (who, _) in found if who and who.get("bot_id")]
    return ("every token is a user token", "pass" if not bots else "fail",
            f"{', '.join(bots)} carry a bot_id, so they cannot read unjoined channels"
            if bots else f"{len([1 for _, (w, _) in found if w])} user token(s)",
            "0 bot tokens")


def every_token_points_at_one_workspace(_conn, found):
    teams = {who.get("team_id") for _, (who, _) in found if who}
    teams.discard(None)
    return ("every token points at one workspace", "pass" if len(teams) <= 1 else "fail",
            f"{len(teams)} workspace(s) across the pool", "1 workspace")


def no_token_is_repeated(_conn, _found):
    trouble = [note for note in shards.problems() if "repeats" in note]
    return ("no token is repeated", "pass" if not trouble else "fail",
            "; ".join(trouble) if trouble else "every token is distinct", "0 repeats")


CHECKS = (
    the_pool_is_configured,
    every_token_is_live,
    every_token_is_a_user_token,
    every_token_points_at_one_workspace,
    no_token_is_repeated,
)


def severity_of(assertion, status):
    if status == "pass":
        return "info"
    return "warn" if assertion in WARN_ONLY else "error"


def record(conn, run_id=None, env=None):
    found = survey(env)
    results = [check(conn, found) for check in CHECKS]
    with conn.cursor() as cur:
        for assertion, status, observed, expected in results:
            cur.execute(RECORD_SQL,
                        (run_id, assertion, severity_of(assertion, status), status, observed, expected))
    conn.commit()
    return results


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        results = record(conn)
    for assertion, status, observed, expected in results:
        print(f"{assertion:36} {status:4}  {observed}  (want {expected})")
    return 1 if any(status == "fail" for _, status, _, _ in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
