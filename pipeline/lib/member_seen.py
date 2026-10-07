def _forward(column):
    return f"""
INSERT INTO fd.member_seen AS seen (user_id, {column})
SELECT user_id, at FROM unnest(%s::text[], %s::timestamptz[]) AS fresh(user_id, at)
WHERE NOT EXISTS (
    SELECT 1 FROM fd.member_seen held
    WHERE held.user_id = fresh.user_id AND held.{column} >= fresh.at
)
ON CONFLICT (user_id) DO UPDATE SET {column} = EXCLUDED.{column}
WHERE seen.{column} IS NULL OR seen.{column} < EXCLUDED.{column}
"""


POSTED_SQL = _forward("last_post_at")
LOGGED_IN_SQL = _forward("last_login_at")


def latest(pairs):
    held = {}
    for user_id, at in pairs:
        if user_id and at is not None and (user_id not in held or at > held[user_id]):
            held[user_id] = at
    return sorted(held.items())


def _write(cur, sql, pairs):
    rows = latest(pairs)
    if rows:
        cur.execute(sql, ([user_id for user_id, _ in rows], [at for _, at in rows]))


def posted(cur, pairs):
    _write(cur, POSTED_SQL, pairs)


def logged_in(cur, pairs):
    _write(cur, LOGGED_IN_SQL, pairs)
