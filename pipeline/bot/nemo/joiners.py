import logging

log = logging.getLogger("bot.nemo")

MEMBER = """
INSERT INTO fd.member (user_id, handle, display_name, avatar_url, avatar_hash,
                       tz, tz_offset, is_bot, is_deleted, is_restricted,
                       is_ultra_restricted, profile_updated_at, synced_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, to_timestamp(%s), now())
ON CONFLICT (user_id) DO UPDATE SET
    handle = coalesce(EXCLUDED.handle, fd.member.handle),
    display_name = coalesce(EXCLUDED.display_name, fd.member.display_name),
    avatar_url = coalesce(EXCLUDED.avatar_url, fd.member.avatar_url),
    avatar_hash = coalesce(EXCLUDED.avatar_hash, fd.member.avatar_hash),
    tz = coalesce(EXCLUDED.tz, fd.member.tz),
    tz_offset = coalesce(EXCLUDED.tz_offset, fd.member.tz_offset),
    is_bot = EXCLUDED.is_bot,
    is_deleted = EXCLUDED.is_deleted,
    is_restricted = EXCLUDED.is_restricted,
    is_ultra_restricted = EXCLUDED.is_ultra_restricted,
    profile_updated_at = coalesce(EXCLUDED.profile_updated_at, fd.member.profile_updated_at),
    synced_at = now()
"""

IDENTITY = """
INSERT INTO fd.member_identity (user_id, real_name, first_name, last_name, email, updated_at)
VALUES (%s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    real_name = coalesce(EXCLUDED.real_name, fd.member_identity.real_name),
    first_name = coalesce(EXCLUDED.first_name, fd.member_identity.first_name),
    last_name = coalesce(EXCLUDED.last_name, fd.member_identity.last_name),
    email = coalesce(EXCLUDED.email, fd.member_identity.email),
    updated_at = now()
WHERE fd.member_identity.purged_at IS NULL
"""

JOINED = """
INSERT INTO fd.member_joins (user_id, joined_at, source)
VALUES (%s, now(), 'team_join')
ON CONFLICT (user_id) DO NOTHING
RETURNING user_id
"""


def said(value):
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def whole(user):
    if not isinstance(user, dict):
        return None
    return user if user.get("id") else None


def member_row(user):
    profile = user.get("profile") or {}
    return (
        user["id"],
        said(user.get("name")),
        said(profile.get("display_name")) or said(profile.get("real_name")),
        said(profile.get("image_512")) or said(profile.get("image_192")),
        said(profile.get("avatar_hash")),
        said(user.get("tz")),
        user.get("tz_offset"),
        bool(user.get("is_bot")),
        bool(user.get("deleted")),
        bool(user.get("is_restricted")),
        bool(user.get("is_ultra_restricted")),
        user.get("updated"),
    )


def identity_row(user):
    profile = user.get("profile") or {}
    return (
        user["id"],
        said(profile.get("real_name")),
        said(profile.get("first_name")),
        said(profile.get("last_name")),
        said(profile.get("email")),
    )


def keep(conn, user):
    conn.execute(MEMBER, member_row(user))
    conn.execute(IDENTITY, identity_row(user))
    return user["id"]


def arrived(conn, user):
    fresh = conn.execute(JOINED, (user["id"],)).fetchone()
    keep(conn, user)
    return bool(fresh)
