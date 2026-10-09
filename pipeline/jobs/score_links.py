import argparse
import re
import sys
from collections import Counter, defaultdict
from itertools import combinations

from dotenv import load_dotenv
from psycopg import errors, sql

from ingest.member_links import catalogue, scoring
from jobs.link_verdicts import VERDICTS
from lib.db import connect
from lib.paths import ENV_FILE

LINKS = "fd.member_link"
TABLE = re.compile(r"^([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)$")
GMAIL_DOMAINS = ("gmail.com", "googlemail.com")
BAND_NAMES = ("certain", "strong", "worth a look")

BANDS_SQL = """
SELECT count(*) FILTER (WHERE score >= %(certain)s),
       count(*) FILTER (WHERE score >= %(strong)s AND score < %(certain)s),
       count(*) FILTER (WHERE score < %(strong)s)
FROM {links}
"""

VERDICTS_SQL = """
SELECT v.a_user_id, v.b_user_id, v.verdict, l.score
FROM fd.member_link_verdict v
LEFT JOIN {links} l ON l.a_user_id = v.a_user_id AND l.b_user_id = v.b_user_id
"""

AMONG_SQL = """
SELECT a_user_id, b_user_id, score
FROM {links}
WHERE a_user_id = ANY(%(ids)s) AND b_user_id = ANY(%(ids)s)
"""

MAILBOXES_SQL = """
SELECT user_id, email FROM fd.member_identity
WHERE email IS NOT NULL AND position('@' IN email) > 0
"""


def links_table(name):
    match = TABLE.match(name or "")
    if not match:
        raise ValueError(f"{name!r} is not a schema.table name")
    return sql.Identifier(*match.groups())


def band_of(score, marks):
    if score >= marks["certain"]:
        return "certain"
    if score >= marks["strong"]:
        return "strong"
    return "worth a look"


def mailbox(email):
    local, at, domain = (email or "").strip().lower().rpartition("@")
    if not at or not domain:
        return None
    local = local.split("+", 1)[0]
    if domain in GMAIL_DOMAINS:
        domain = GMAIL_DOMAINS[0]
        local = local.replace(".", "")
    if not local:
        return None
    return f"{local}@{domain}"


def staff_domain(domain, staff):
    return any(domain == one or domain.endswith(f".{one}") for one in staff)


def alias_pairs(rows, staff):
    boxes = defaultdict(set)
    for user_id, email in rows:
        box = mailbox(email)
        if box and not staff_domain(box.rpartition("@")[2], staff):
            boxes[box].add(user_id)
    return {pair for users in boxes.values() for pair in combinations(sorted(users), 2)}


def people(pairs):
    parent = {}

    def root(one):
        parent.setdefault(one, one)
        while parent[one] != one:
            parent[one] = parent[parent[one]]
            one = parent[one]
        return one

    for a, b in pairs:
        parent[root(a)] = root(b)
    groups = defaultdict(set)
    for one in list(parent):
        groups[root(one)].add(one)
    return sorted(groups.values(), key=lambda group: (-len(group), min(group)))


def hub(person, pairs):
    counts = Counter(one for pair in pairs for one in pair if one in person)
    return min(person, key=lambda one: (-counts[one], one))


def together(person, links):
    inside = [(a, b) for a, b in links if a in person and b in person]
    groups = people(inside)
    return len(groups[0]) if groups else 0


def found(pairs, scores, marks):
    bands = Counter(band_of(scores[pair], marks) for pair in pairs if pair in scores)
    return {"pairs": len(pairs), "linked": sum(bands.values()), "bands": bands}


def measure(conn, links_name=LINKS):
    marks = scoring()
    staff = catalogue().get("staff_domains", [])
    links = links_table(links_name)

    def query(text, params=None):
        return conn.execute(sql.SQL(text).format(links=links), params).fetchall()

    banded = query(BANDS_SQL, marks)[0]
    rows = query(VERDICTS_SQL)

    by_verdict = defaultdict(set)
    scores = {}
    for a, b, verdict, score in rows:
        by_verdict[verdict].add((a, b))
        if score is not None:
            scores[(a, b)] = float(score)
    verdicts = {verdict: found(by_verdict[verdict], scores, marks) for verdict in VERDICTS}

    confirmed = by_verdict["same_person"]
    groups = people(confirmed)
    accounts = sorted(set().union(*groups)) if groups else []
    among = query(AMONG_SQL, {"ids": accounts}) if accounts else []
    every = [(a, b) for a, b, _score in among]
    strong = [(a, b) for a, b, score in among if float(score) >= marks["strong"]]
    confirmed_people = [
        {"hub": hub(group, confirmed), "accounts": len(group),
         "together": together(group, every), "strong_together": together(group, strong)}
        for group in groups
    ]

    aliases = alias_pairs(conn.execute(MAILBOXES_SQL).fetchall(), staff)
    alias_ids = sorted({one for pair in aliases for one in pair})
    alias_links = query(AMONG_SQL, {"ids": alias_ids}) if alias_ids else []
    alias_scores = {(a, b): float(score) for a, b, score in alias_links if (a, b) in aliases}

    return {
        "links": links_name,
        "bands": dict(zip(BAND_NAMES, banded, strict=True)),
        "verdicts": verdicts,
        "people": confirmed_people,
        "aliases": found(aliases, alias_scores, marks),
    }


def share(part, whole):
    return f"{round(100 * part / whole)}%" if whole else "n/a"


def band_line(bands):
    return ", ".join(f"{name} {bands.get(name, 0):,}" for name in BAND_NAMES)


def render(result):
    bands = result["bands"]
    lines = [f"links in {result['links']}: {sum(bands.values()):,} ({band_line(bands)})", ""]

    lines.append("verdict pairs the finder links")
    for verdict, one in result["verdicts"].items():
        lines.append(f"  {verdict:<17} {one['linked']:>6,} of {one['pairs']:<6,} "
                     f"{share(one['linked'], one['pairs']):>4}  {band_line(one['bands'])}")
    lines.append("")

    confirmed = result["people"]
    total = sum(one["accounts"] for one in confirmed)
    linked = sum(one["together"] for one in confirmed)
    strong = sum(one["strong_together"] for one in confirmed)
    lines.append(f"people confirmed by same_person verdicts: {len(confirmed):,}, {total:,} accounts")
    for one in confirmed:
        lines.append(f"  {one['hub']:<13} {one['accounts']:>4} accounts  "
                     f"{one['together']:>4} linked together  "
                     f"{one['strong_together']:>4} at strong or above")
    if confirmed:
        lines.append(f"  {'all':<13} {total:>4} accounts  {linked:>4} linked together "
                     f"({share(linked, total)})  {strong:>4} at strong or above "
                     f"({share(strong, total)})")
    lines.append("")

    aliases = result["aliases"]
    lines.append(f"email aliases outside staff domains: {aliases['linked']:,} of "
                 f"{aliases['pairs']:,} linked ({share(aliases['linked'], aliases['pairs'])}): "
                 f"{band_line(aliases['bands'])}")
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description="score the alt finder against link verdicts")
    parser.add_argument("--links", default=LINKS,
                        help="schema.table holding a_user_id < b_user_id and score, like fd.member_link")
    parser.add_argument("--dsn", help="Postgres DSN to use instead of the environment configuration")
    args = parser.parse_args(argv)
    load_dotenv(ENV_FILE)
    try:
        links_table(args.links)
    except ValueError as refusal:
        print(f"check-links: {refusal}", file=sys.stderr)
        return 2
    try:
        with connect(args.dsn) as conn:
            conn.read_only = True
            result = measure(conn, args.links)
    except (errors.UndefinedTable, errors.UndefinedColumn) as refusal:
        print(f"check-links: {str(refusal).splitlines()[0]}", file=sys.stderr)
        return 2
    print("\n".join(render(result)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
