import logging

from bot.core import audit, privileged, session

log = logging.getLogger("bot.nemo.publicize")

COMMAND = "/publicize"
CHANNEL_MANAGER_ROLE = "Rl0A"

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


def channel_managers(channel_id):
    response = call("admin.roles.entity.listAssignments",
                    {"entity_id": channel_id, "role_id": CHANNEL_MANAGER_ROLE})
    return {
        user
        for assignment in response.get("role_assignments") or []
        if assignment.get("role_id") == CHANNEL_MANAGER_ROLE
        for user in assignment.get("users") or []
    }


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
