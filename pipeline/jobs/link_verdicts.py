import argparse
import re
import sys

from dotenv import load_dotenv

from bot.core import audit
from lib.db import connect
from lib.paths import ENV_FILE

USER_ID = re.compile(r"^[UW][A-Z0-9]{2,}$")
VERDICTS = ("same_person", "different_people", "household", "staff_test")
ONE_PERSON = ("same_person", "staff_test")
ENTITY_TYPE = "member_link_verdict"

KNOWN_SQL = "SELECT user_id FROM fd.member WHERE user_id = ANY(%s)"

HELD_SQL = """
SELECT id, verdict, decided_by, note
FROM fd.member_link_verdict
WHERE a_user_id = %s AND b_user_id = %s
FOR UPDATE
"""

INSERT_SQL = """
INSERT INTO fd.member_link_verdict (a_user_id, b_user_id, verdict, decided_by, note)
VALUES (%s, %s, %s, %s, %s)
RETURNING id
"""

UPDATE_SQL = """
UPDATE fd.member_link_verdict
SET verdict = %s, decided_by = %s, decided_at = now(), note = %s
WHERE id = %s
"""


class VerdictError(ValueError):
    pass


def ordered(one, other):
    return (one, other) if one < other else (other, one)


def verb_for(verdict):
    return "linked" if verdict in ONE_PERSON else "unlinked"


def split_ids(values):
    return [piece.strip() for value in values or [] for piece in value.split(",") if piece.strip()]


def planned(by, main, chosen):
    malformed = [one for one in [by, main] if not USER_ID.match(one or "")]
    picks = {}
    for verdict in VERDICTS:
        for account in split_ids(chosen.get(verdict)):
            if not USER_ID.match(account):
                malformed.append(account)
            elif account == main:
                raise VerdictError(f"{account} is the main account, it cannot be paired with itself")
            elif picks.get(account, verdict) != verdict:
                raise VerdictError(f"{account} is listed under both {picks[account]} and {verdict}")
            else:
                picks[account] = verdict
    if malformed:
        raise VerdictError(f"not Slack user IDs: {', '.join(malformed)}")
    if not picks:
        raise VerdictError("no accounts listed, pass at least one of " +
                           ", ".join(f"--{one.replace('_', '-')}" for one in VERDICTS))
    return picks


def unknown(conn, ids):
    rows = conn.execute(KNOWN_SQL, (sorted(ids),)).fetchall()
    held = {row[0] for row in rows}
    return sorted(set(ids) - held)


def record(conn, by, main, account, verdict, note=None):
    a, b = ordered(main, account)
    held = conn.execute(HELD_SQL, (a, b)).fetchone()
    before = None
    if held is None:
        row = conn.execute(INSERT_SQL, (a, b, verdict, by, note)).fetchone()
        verdict_id = row[0]
        outcome = "recorded"
    else:
        verdict_id, was, was_by, was_note = held
        note = was_note if note is None else note
        if (was, was_note) == (verdict, note):
            return "unchanged"
        conn.execute(UPDATE_SQL, (verdict, by, note, verdict_id))
        before = {"verdict": was, "decided_by": was_by, "note": was_note}
        outcome = "changed"
    after = {"a_user_id": a, "b_user_id": b, "verdict": verdict, "decided_by": by, "note": note}
    audit.record(conn, ENTITY_TYPE, verdict_id, verb_for(verdict), by,
                 before=before, after=after, subject_user_id=account)
    return outcome


def run(conn, by, main, picks, note=None):
    missing = unknown(conn, {by, main, *picks})
    if missing:
        raise VerdictError(f"not in fd.member: {', '.join(missing)}")
    tally = {}
    for account, verdict in sorted(picks.items()):
        outcome = record(conn, by, main, account, verdict, note)
        tally[outcome] = tally.get(outcome, 0) + 1
        print(f"{outcome:<9} {verdict:<16} {main} {account}")
    conn.commit()
    print(", ".join(f"{count} {outcome}" for outcome, count in sorted(tally.items())))
    return tally


def parser():
    held = argparse.ArgumentParser(
        prog="nemo verdict",
        description="record a verdict for each listed account paired with the main account",
    )
    held.add_argument("--by", required=True, help="Slack user ID of the person deciding")
    held.add_argument("--main", required=True, help="Slack user ID every listed account is paired with")
    for verdict in VERDICTS:
        held.add_argument(f"--{verdict.replace('_', '-')}", dest=verdict, nargs="+",
                          metavar="USER_ID", help="Slack user IDs, space or comma separated")
    held.add_argument("--note", help="kept on every pair recorded in this run")
    held.add_argument("--dsn", help="Postgres DSN to use instead of the environment configuration")
    return held


def main(argv=None):
    args = parser().parse_args(argv)
    load_dotenv(ENV_FILE)
    note = (args.note or "").strip() or None
    try:
        picks = planned(args.by, args.main, {one: getattr(args, one) for one in VERDICTS})
        with connect(args.dsn) as conn:
            run(conn, args.by, args.main, picks, note)
    except VerdictError as refusal:
        print(f"nemo verdict: {refusal}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
