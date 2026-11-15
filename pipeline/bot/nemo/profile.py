import datetime as dt
import logging
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

log = logging.getLogger("bot.nemo")

PROFILE_CACHE = {}
ZONE_CACHE = {}

IMAGES = ("image_192", "image_72", "image_48", "image_512", "image_original")


def profile(client, user_id):
    if not user_id:
        return {"name": "unknown", "icon": None}
    if user_id in PROFILE_CACHE:
        return PROFILE_CACHE[user_id]

    member_profile = {"name": user_id, "icon": None}
    try:
        response = client.users_info(user=user_id)
        profile = response["user"].get("profile", {})
        member_profile["name"] = (
            profile.get("display_name")
            or response["user"].get("real_name")
            or user_id
        )
        member_profile["icon"] = next((profile[key] for key in IMAGES if profile.get(key)), None)
    except Exception as failure:
        log.warning("nemo: could not look up %s: %s", user_id, failure)

    PROFILE_CACHE[user_id] = member_profile
    return member_profile


def name(client, user_id):
    return profile(client, user_id)["name"]


def timezone(client, user_id):
    if user_id in ZONE_CACHE:
        return ZONE_CACHE[user_id]

    zone = dt.UTC
    try:
        name = client.users_info(user=user_id)["user"].get("tz")
        zone = ZoneInfo(name) if name else dt.UTC
    except ZoneInfoNotFoundError:
        zone = dt.UTC
    except Exception as failure:
        log.warning("nemo: could not read the time zone of %s: %s", user_id, failure)
        return dt.UTC

    ZONE_CACHE[user_id] = zone
    return zone


def timezone_name(client, user_id):
    return getattr(timezone(client, user_id), "key", None)
