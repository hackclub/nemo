import logging
import threading

log = logging.getLogger("bot.nemo")

EXACT = "exact"
SUFFIX = "suffix"

FLAG = "flag"
HOLD = "hold"
DEACTIVATE = "deactivate"

ALLOWED = "allowed"
FLAGGED = "flagged"
HELD = "held"
DEACTIVATED = "deactivated"
FAILED = "failed"
NO_EMAIL = "no_email"

WORST_FIRST = (DEACTIVATE, HOLD, FLAG)

LANDED = {FLAG: FLAGGED, HOLD: HELD, DEACTIVATE: DEACTIVATED}

SHUSH_DAYS = 7

SAID = {
    FLAGGED: "joined on {domain}, which is flagged",
    HELD: "joined on {domain} and is shushed",
    DEACTIVATED: "joined on {domain} and is deactivated",
    FAILED: "joined on {domain} but nemo could not hold them",
}

LIVE = """
SELECT id, domain, match_mode, effect
FROM fd.blocked_domains
WHERE active
ORDER BY id
"""

SCREENED = """
INSERT INTO fd.join_screen
    (user_id, email_domain, domain_id, matched, effect, outcome, guard_id, detail)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (user_id) DO NOTHING
RETURNING id
"""

_watching = []
_loaded = False
_lock = threading.Lock()


class Watch:
    def __init__(self, domain_id, domain, match_mode, effect):
        self.domain_id = domain_id
        self.domain = (domain or "").strip().lower()
        self.match_mode = match_mode
        self.effect = effect

    def holds(self, said):
        if not self.domain or not said:
            return False
        if self.match_mode == EXACT:
            return said == self.domain
        return said == self.domain or said.endswith(f".{self.domain}")


def refresh(conn):
    global _loaded
    found = [Watch(*row) for row in conn.execute(LIVE).fetchall()]
    with _lock:
        _watching[:] = found
        _loaded = True
    return len(found)


def watching():
    with _lock:
        return list(_watching) if _loaded else None


def domain_of(email):
    said = (email or "").strip().lower()
    if "@" not in said:
        return None
    held = said.rsplit("@", 1)[-1].strip()
    return held or None


def worst(said):
    held = watching()
    if not held or not said:
        return None

    caught = [one for one in held if one.holds(said)]
    if not caught:
        return None
    return min(caught, key=lambda one: WORST_FIRST.index(one.effect))


def record(conn, user_id, domain, found, outcome, guard_id=None, detail=None):
    return conn.execute(SCREENED, (
        user_id, domain,
        found.domain_id if found else None,
        found.domain if found else None,
        found.effect if found else None,
        outcome, guard_id, detail,
    )).fetchone()


def tell_the_house(client, conn, user_id, domain, outcome):
    if client is None or outcome not in SAID:
        return None

    from bot.nemo import channel

    room = channel.firehouse_channel(conn)
    if not room:
        return None

    try:
        client.chat_postMessage(
            channel=room,
            text=f"<@{user_id}> {SAID[outcome].format(domain=domain)}.",
            unfurl_links=False,
        )
    except Exception as failure:  # noqa: BLE001
        log.warning("nemo: could not say that %s was screened: %s", user_id, failure)
        return None
    return room


def screen(conn, user_id, email, by="nemo", client=None):
    domain = domain_of(email)
    if domain is None:
        record(conn, user_id, None, None, NO_EMAIL)
        return NO_EMAIL, None

    found = worst(domain)
    if found is None:
        record(conn, user_id, domain, None, ALLOWED)
        return ALLOWED, None

    if found.effect == FLAG:
        record(conn, user_id, domain, found, FLAGGED)
        log.warning("nemo: %s joined on %s, which is flagged", user_id, domain)
        tell_the_house(client, conn, user_id, domain, FLAGGED)
        return FLAGGED, None

    guard_id, trouble = hold_them(conn, user_id, found, by)
    if guard_id is None:
        record(conn, user_id, domain, found, FAILED, detail=trouble)
        log.warning("nemo: %s joined on %s but the guard would not open: %s",
                    user_id, domain, trouble)
        tell_the_house(client, conn, user_id, domain, FAILED)
        return FAILED, None

    outcome = LANDED[found.effect]
    record(conn, user_id, domain, found, outcome, guard_id=guard_id)
    log.warning("nemo: %s joined on %s, %s", user_id, domain, outcome)
    tell_the_house(client, conn, user_id, domain, outcome)
    return outcome, guard_id


def hold_them(conn, user_id, found, by):
    from bot.nemo import memberguards

    kind = memberguards.DEACTIVATION if found.effect == DEACTIVATE else memberguards.SHUSH
    reason = f"joined on {found.domain}, which the domain list holds"
    expires = None if kind == memberguards.DEACTIVATION else shush_until(conn)

    try:
        guard_id = memberguards.open_guard(
            conn, kind, user_id, by, reason, expires_at=expires
        )
    except Exception as failure:  # noqa: BLE001
        return None, str(failure)[:500]

    if guard_id is None:
        return None, "a guard of that kind already stands on them"
    return guard_id, None


def shush_until(conn):
    row = conn.execute(
        "SELECT now() + make_interval(days => %s)", (SHUSH_DAYS,)
    ).fetchone()
    return row[0] if row else None
