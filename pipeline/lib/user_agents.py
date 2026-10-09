import hashlib

from lib import useragent

UPSERT_SQL = """
INSERT INTO slack.user_agent (ua, app, os, read_at)
SELECT ua, app, os, now() FROM unnest(%s::text[], %s::text[], %s::text[]) AS fresh(ua, app, os)
ON CONFLICT (md5(ua)) DO NOTHING
"""

IDS_SQL = "SELECT md5(ua), id FROM slack.user_agent WHERE md5(ua) = ANY(%s)"


def digest(ua):
    return hashlib.md5(ua.encode()).hexdigest()


def ids(conn, agents):
    held = sorted({one for one in agents if one})
    if not held:
        return {}
    read = [useragent.parse(one) for one in held]
    conn.execute(UPSERT_SQL, (held, [one["ua_app"] for one in read], [one["ua_os"] for one in read]))
    return dict(conn.execute(IDS_SQL, ([digest(one) for one in held],)).fetchall())


def id_of(agents, ua):
    return agents.get(digest(ua)) if ua else None
