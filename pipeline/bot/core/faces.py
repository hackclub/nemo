import json
import logging
import threading
import urllib.error
import urllib.request
from urllib.parse import quote

log = logging.getLogger("bot.faces")

HOST = "https://cachet.hackclub.com/users"
TIMEOUT = 5
UNKNOWN = "Unknown"

KNOWN = {}
LOCK = threading.Lock()


def icon_url(user_id):
    return f"{HOST}/{quote(user_id, safe='')}/r"


def fetch(user_id):
    request = urllib.request.Request(
        f"{HOST}/{quote(user_id, safe='')}", headers={"Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as answer:
            body = json.loads(answer.read())
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as trouble:
        log.warning("faces: could not ask cachet about %s: %s", user_id, trouble)
        return None

    said = body.get("displayName")
    return said if said and said != UNKNOWN else None


def name(user_id):
    if not user_id:
        return None
    with LOCK:
        if user_id in KNOWN:
            return KNOWN[user_id]

    found = fetch(user_id)
    with LOCK:
        KNOWN[user_id] = found
    return found
