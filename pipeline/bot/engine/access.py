import os

import yaml

from lib.paths import PERMISSIONS_FILE

ROLE = """
SELECT role FROM fd.access_grants
WHERE user_id = %s AND revoked_at IS NULL
ORDER BY granted_at DESC
LIMIT 1
"""

MANAGER = """
SELECT 1 FROM app.staff WHERE user_id = %s AND community_manager
"""

MANAGER_ROLE = "community_manager"
BOOTSTRAP = "BOOTSTRAP_ADMIN_SLACK_ID"

MOVED = """
SELECT role, allowed FROM fd.role_permissions
WHERE permission_key = %s
ORDER BY changed_at
"""

HOLDERS = """
SELECT user_id FROM fd.case_assignees WHERE case_id = %s
"""


TABLE = None


def table():
    global TABLE
    if TABLE is None:
        TABLE = yaml.safe_load(PERMISSIONS_FILE.read_text())
    return TABLE


def rank():
    return table()["roles"]


def labels():
    return table()["role_labels"]


def entry(key):
    found = table()["permissions"].get(key)
    if found is None:
        raise KeyError(f"{key} is not a permission")
    return found


def default_roles(key):
    return table()["role_sets"][entry(key)["held_by"]]


def bootstrap_ids():
    return [one.strip() for one in os.environ.get(BOOTSTRAP, "").split(",") if one.strip()]


def manager(conn, user_id):
    if not user_id:
        return False
    if user_id in bootstrap_ids():
        return True
    return conn.execute(MANAGER, (user_id,)).fetchone() is not None


def role(conn, user_id):
    if not user_id:
        return None
    if manager(conn, user_id):
        return MANAGER_ROLE
    row = conn.execute(ROLE, (user_id,)).fetchone()
    return row[0] if row else None


def holders(conn, key):
    held = set(default_roles(key))
    for named, allowed in conn.execute(MOVED, (key,)).fetchall():
        if allowed:
            held.add(named)
        else:
            held.discard(named)
    return [named for named in rank() if named in held]


def least(conn, key):
    return next(iter(holders(conn, key)), None)


def refusal(conn, key):
    lowest = least(conn, key)
    if lowest is None:
        return "nobody holds that"
    if lowest == rank()[0]:
        return "that is not yours"
    return f"{entry(key)['label'].lower()} is {labels()[lowest].lower()} only"


def free_or_theirs(conn, case_id, user_id):
    held = [row[0] for row in conn.execute(HOLDERS, (case_id,)).fetchall()]
    if not held or user_id in held:
        return True, None
    who = ", ".join(f"<@{one}>" for one in held)
    return False, f"case {case_id} is with {who}, not with you"


def in_scope(conn, key, user_id, case_id):
    scope = entry(key).get("scope")
    if scope != "assigned" or case_id is None:
        return True, None
    return free_or_theirs(conn, case_id, user_id)


def may(conn, user_id, key, case_id=None):
    held = role(conn, user_id)
    if held is None:
        return False, "you need a Fire Department grant to do that"

    if held not in holders(conn, key):
        return False, refusal(conn, key)

    return in_scope(conn, key, user_id, case_id)
