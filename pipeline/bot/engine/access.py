ROLE = """
SELECT role FROM fd.access_grants
WHERE user_id = %s AND revoked_at IS NULL
ORDER BY granted_at DESC
LIMIT 1
"""

OVERRIDE = """
SELECT allowed FROM fd.role_permissions
WHERE role = %s AND permission_key = %s
ORDER BY changed_at DESC
LIMIT 1
"""


def role(conn, user_id):
    if not user_id:
        return None
    row = conn.execute(ROLE, (user_id,)).fetchone()
    return row[0] if row else None


def may(conn, user_id, key):
    held = role(conn, user_id)
    if held is None:
        return False, "you need a Fire Department grant to do that"

    row = conn.execute(OVERRIDE, (held, key)).fetchone()
    if row is not None and not row[0]:
        return False, f"a {held.replace('_', ' ')} is not allowed to do that"

    return True, None
