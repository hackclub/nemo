import logging

log = logging.getLogger("bot.nemo")

KNOWN = {}

IMAGES = ("image_192", "image_72", "image_48", "image_512", "image_original")


def face(client, user_id):
    if not user_id:
        return {"name": "somebody", "icon": None}
    if user_id in KNOWN:
        return KNOWN[user_id]

    seen = {"name": user_id, "icon": None}
    try:
        answer = client.users_info(user=user_id)
        profile = answer["user"].get("profile", {})
        seen["name"] = (
            profile.get("display_name")
            or answer["user"].get("real_name")
            or user_id
        )
        seen["icon"] = next((profile[key] for key in IMAGES if profile.get(key)), None)
    except Exception as failure:
        log.warning("nemo: could not look up %s: %s", user_id, failure)

    KNOWN[user_id] = seen
    return seen


def name(client, user_id):
    return face(client, user_id)["name"]
