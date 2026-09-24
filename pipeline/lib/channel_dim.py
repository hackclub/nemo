PUBLIC = "public"
PRIVATE = "private"

UPSERT = """
INSERT INTO raw.channel_dim (channel_id, name, archived, visibility, updated_at)
VALUES (%s, %s, %s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET
    name = COALESCE(EXCLUDED.name, raw.channel_dim.name),
    archived = COALESCE(EXCLUDED.archived, raw.channel_dim.archived),
    visibility = COALESCE(EXCLUDED.visibility, raw.channel_dim.visibility),
    name_unavailable = false,
    updated_at = now()
"""


def visibility_of(channel):
    if "is_private" not in channel:
        return None
    return PRIVATE if channel["is_private"] else PUBLIC


def record(conn, channel_id, name=None, archived=None, visibility=None):
    with conn.cursor() as cur:
        cur.execute(UPSERT, (channel_id, name, archived, visibility))
    return channel_id
