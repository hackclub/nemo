CAPABILITY = """
SELECT label, record_scope, every_account FROM app.capability WHERE key = %s
"""

MAY_SEE_CHANNEL = """
SELECT app.may_see_channel(%s, %s)
"""

HOLDS = """
SELECT app.holds_capability(%s, %s)
"""

ROLES = """
SELECT role FROM app.effective_role WHERE user_id = %s ORDER BY role
"""

CARRIED = ("author", "channel")


class UnknownCapabilityError(KeyError):
    """Raised when db/capabilities.yml has no capability under this key."""


def entry(conn, key):
    row = conn.execute(CAPABILITY, (key,)).fetchone()
    if row is None:
        raise UnknownCapabilityError(f"{key} is not a capability")
    return {"label": row[0], "record_scope": row[1], "every_account": bool(row[2])}


def roles(conn, user_id):
    if not user_id:
        return []
    return [row[0] for row in conn.execute(ROLES, (user_id,)).fetchall()]


def role(conn, user_id):
    held = roles(conn, user_id)
    return held[0] if held else None


def holds(conn, user_id, key):
    if not user_id:
        return False
    return bool(conn.execute(HOLDS, (user_id, key)).fetchone()[0])


def refusal(cap):
    return f"{cap['label'].lower()} is not yours to use"


def in_scope(cap):
    scope = cap["record_scope"]
    if scope is None or scope in CARRIED:
        return True, None
    return False, f"{cap['label'].lower()} is scoped to {scope}, which nemo cannot weigh"


def may_see_channel(conn, user_id, channel_id):
    if not user_id or not channel_id:
        return False
    return bool(conn.execute(MAY_SEE_CHANNEL, (user_id, channel_id)).fetchone()[0])


def may(conn, user_id, key, case_id=None):
    cap = entry(conn, key)
    if cap["every_account"]:
        return in_scope(cap)
    if not roles(conn, user_id) and not holds(conn, user_id, key):
        return False, "you need a Fire Department grant to do that"
    if not holds(conn, user_id, key):
        return False, refusal(cap)

    return in_scope(cap)
