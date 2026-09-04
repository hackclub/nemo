import logging
import urllib.error
import urllib.request

from bot.engine import files, session

log = logging.getLogger("bot.shroud")

TIMEOUT = 30


def download(url, token, limit):
    if not files.slack_url(url):
        return None, "refused", "the file url is not an https slack url"

    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as answer:
            kind = answer.headers.get("Content-Type")
            declared = answer.headers.get("Content-Length")
            if declared and int(declared) > limit:
                return None, "too_large", f"{declared} bytes is over the {limit} byte limit"
            body = answer.read(limit + 1)
            if len(body) > limit:
                return None, "too_large", f"over the {limit} byte limit"
            state, error = files.verdict(answer.status, kind, len(body), limit)
            return (body if state == "stored" else None), state, error
    except urllib.error.HTTPError as refusal:
        state, error = files.verdict(refusal.code, None, 0, limit)
        return None, state, error
    except (urllib.error.URLError, TimeoutError, OSError) as trouble:
        return None, "failed", f"could not reach slack: {trouble}"


def drain(token, limit=20):
    kept = 0
    with session() as conn:
        rows = files.waiting(conn, limit)

    for file_id, slack_id, url, size, mimetype in rows:
        if files.too_big_to_ask(size):
            with session() as conn:
                files.give_up(conn, file_id, "too_large", f"{size} bytes, we do not ask for it")
            log.info("shroud: %s is too large to keep", slack_id)
            continue

        body, state, error = download(url, token, files.cap())
        with session() as conn:
            if state == "stored":
                files.keep(conn, file_id, body, mimetype)
                kept += 1
            else:
                files.give_up(conn, file_id, state, error)
        log.info("shroud: %s is %s", slack_id, state)
    return kept
