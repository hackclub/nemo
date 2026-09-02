CAPABILITY = """
SELECT label, record_scope FROM app.capability WHERE key = %s
"""

HOLDS = """
SELECT app.holds_capability(%s, %s)
"""

ROLES = """
SELECT role FROM app.effective_role WHERE user_id = %s ORDER BY role
"""

HOLDERS = """
SELECT user_id FROM fd.case_assignees WHERE case_id = %s
"""


class Unknown(KeyError):
    """No capability in db/capabilities.yml carries this key"""


def entry(conn, key):
    row = conn.execute(CAPABILITY, (key,)).fetchone()
    if row is None:
        raise Unknown(f"{key} is not a capability")
    return {"label": row[0], "record_scope": row[1]}


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


def refusal(said):
    return f"{said['label'].lower()} is not yours to use"


def free_or_theirs(conn, case_id, user_id):
    held = [row[0] for row in conn.execute(HOLDERS, (case_id,)).fetchall()]
    if not held or user_id in held:
        return True, None
    who = ", ".join(f"<@{one}>" for one in held)
    return False, f"case {case_id} is with {who}, not with you"


def in_scope(conn, said, user_id, case_id):
    if said["record_scope"] != "assigned" or case_id is None:
        return True, None
    return free_or_theirs(conn, case_id, user_id)


def may(conn, user_id, key, case_id=None):
    said = entry(conn, key)
    if not roles(conn, user_id) and not holds(conn, user_id, key):
        return False, "you need a Fire Department grant to do that"
    if not holds(conn, user_id, key):
        return False, refusal(said)

    return in_scope(conn, said, user_id, case_id)
