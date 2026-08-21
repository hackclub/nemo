import logging

log = logging.getLogger("bot.nemo")

KNOWN = {}


def name(client, user_id):
    if not user_id:
        return "somebody"
    if user_id in KNOWN:
        return KNOWN[user_id]

    said = user_id
    try:
        answer = client.users_info(user=user_id)
        profile = answer["user"]
        said = profile.get("profile", {}).get("display_name") or profile.get("real_name") or user_id
    except Exception as failure:
        log.warning("nemo: could not look up %s: %s", user_id, failure)

    KNOWN[user_id] = said
    return said
