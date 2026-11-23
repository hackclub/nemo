import logging
import os

from bot.core import audit, privileged, session

log = logging.getLogger("bot.nemo.publicize")

COMMAND = "/publicize"
CHANNEL_MANAGER_ROLE = "Rl0A"
MANAGER_TTL = "1 hour"
PAGE_CAP = 20

ALREADY_PUBLIC = ":neocat: this channel already public"
REFUSED = ":bleh: sorry it doesnt appear you're an admin, the cm, or the creator"
DONE = ":kitty-wow: meoww ur channel public now :3"
FAILED = "Couldn't convert this channel. Try again, or ping an admin."


def call(method, params):
    return privileged.proxy().call(method, params, credential="admin", max_retries=1) or {}


def channel_info(channel_id):
    try:
        channel = call("conversations.info", {"channel": channel_id}).get("channel") or {}
        return channel.get("is_private") is not False, channel.get("creator")
    except Exception as failure:  # noqa: BLE001
        log.info("publicize: cannot read %s, trying admin search: %s", channel_id, failure)
    return search_channel(channel_id)


def search_channel(channel_id):
    """Admin search sees every channel in the org, member or not."""
    try:
        found = call("admin.conversations.search", {"query": channel_id, "limit": 10})
    except Exception as failure:  # noqa: BLE001
        log.info("publicize: admin search failed for %s, assuming private: %s", channel_id, failure)
        return True, None
    for channel in found.get("conversations") or []:
        if channel.get("id") == channel_id:
            return channel.get("is_private") is not False, channel.get("creator_id")
    return True, None


def is_admin(user_id):
    user = privileged.profile(user_id) or {}
    return any(user.get(flag) for flag in ("is_admin", "is_owner", "is_primary_owner"))


def role_id():
    return os.environ.get("SLACK_CHANNEL_MANAGER_ROLE_ID", "").strip() or CHANNEL_MANAGER_ROLE


FRESH_MANAGERS = f"""
SELECT array(SELECT user_id FROM api.channel_manager WHERE channel_id = %s)
FROM api.channel_sweep WHERE channel_id = %s AND synced_at > now() - interval '{MANAGER_TTL}'
"""


def cached_managers(channel_id):
    """The managers the web API's channel-manager check cached, if fresh."""
    with session() as conn:
        row = conn.execute(FRESH_MANAGERS, (channel_id, channel_id)).fetchone()
    return set(row[0]) if row else None


def fetch_managers(channel_id):
    managers, cursor = set(), None
    for _ in range(PAGE_CAP):
        page = call("admin.roles.listAssignments",
                    {"role_ids": role_id(), "entity_ids": channel_id, "limit": 200, "cursor": cursor})
        managers |= {row["user_id"] for row in page.get("role_assignments") or []
                     if row.get("entity_id") == channel_id and row.get("user_id")}
        cursor = (page.get("response_metadata") or {}).get("next_cursor")
        if not cursor:
            break
    return managers


def store_managers(channel_id, managers):
    with session() as conn:
        conn.execute("DELETE FROM api.channel_manager WHERE channel_id = %s", (channel_id,))
        for user in managers:
            conn.execute("INSERT INTO api.channel_manager (channel_id, user_id) VALUES (%s, %s)",
                         (channel_id, user))
        conn.execute(
            "INSERT INTO api.channel_sweep (channel_id, synced_at, managers) VALUES (%s, now(), %s) "
            "ON CONFLICT (channel_id) DO UPDATE SET synced_at = now(), managers = EXCLUDED.managers",
            (channel_id, len(managers)))


def channel_managers(channel_id):
    """Same source as the /api/v1/channels/{id}/managers/{user} check."""
    cached = cached_managers(channel_id)
    if cached is not None:
        return cached
    managers = fetch_managers(channel_id)
    store_managers(channel_id, managers)
    return managers


def may_publicize(user_id, channel_id, creator):
    if is_admin(user_id):
        return True
    managers = channel_managers(channel_id)
    if managers:
        return user_id in managers
    return creator == user_id


def publicize(user_id, channel_id):
    is_private, creator = channel_info(channel_id)
    if not is_private:
        return ALREADY_PUBLIC
    if not may_publicize(user_id, channel_id, creator):
        return REFUSED
    try:
        call("admin.conversations.convertToPublic", {"channel_id": channel_id})
    except Exception as failure:  # noqa: BLE001
        log.warning("publicize: could not convert %s: %s", channel_id, failure)
        return FAILED
    with session() as conn:
        audit.record(conn, "channel", 0, "publicized", user_id, after={"channel_id": channel_id})
    log.info("publicize: %s made %s public", user_id, channel_id)
    return DONE


def register(app):
    @app.command(COMMAND)
    def on_publicize(ack, command, respond):
        ack()
        try:
            text = publicize(command["user_id"], command["channel_id"])
        except Exception:
            log.exception("publicize: failed for %s", command.get("channel_id"))
            text = FAILED
        respond(text=text, response_type="ephemeral")
