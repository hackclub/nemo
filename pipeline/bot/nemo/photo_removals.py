import hashlib
import logging
import threading
import time
import urllib.request
from collections import namedtuple
from urllib.parse import urlparse

from bot.core import audit, privileged, session

log = logging.getLogger("bot.nemo")

ENTITY_TYPE = "member_photo"

PER_PASS = 20
GIVE_UP_AFTER = 3
MAX_IMAGE_BYTES = 10_000_000
FETCH_TIMEOUT_SECONDS = 20
REFRESH_ATTEMPTS = 3
REFRESH_DELAY_SECONDS = 2

IMAGE_HOSTS = frozenset({
    "avatars.slack-edge.com", "a.slack-edge.com", "secure.gravatar.com",
    "i0.wp.com", "i1.wp.com", "i2.wp.com", "i3.wp.com",
})
IMAGE_KEYS = ("image_original", "image_1024", "image_512", "image_192")
IMAGE_TYPES = frozenset({"image/png", "image/jpeg", "image/gif", "image/webp"})
FALLBACK_TYPE = "application/octet-stream"

DONE = "done"
FAILED = "failed"
DEACTIVATION_CANCELLED = "Deactivation cancelled"

MAX_REASON_LENGTH = 500
REASON_TOO_LONG = f"Reason must be under {MAX_REASON_LENGTH} characters"
QUEUED_ANSWER = "Pfp removal queued for <@{member_id}>"
ALREADY_QUEUED_ANSWER = "Pfp removal already queued for <@{member_id}>"

Removal = namedtuple("Removal", "id member_id asked_by attempts")
Original = namedtuple("Original", "url avatar_hash image content_type")

INTERRUPTED = """
UPDATE fd.photo_removals
SET state = 'asked'
WHERE state = 'running' AND started_at < now() - interval '10 minutes'
"""

CANCELLED = """
UPDATE fd.photo_removals r
SET state = 'failed', error = %s, finished_at = now()
FROM fd.member_guards g
WHERE g.id = r.guard_id
  AND r.state = 'asked'
  AND g.enforcement_status <> 'held'
  AND g.state IN ('lifted', 'cancelled')
"""

READY = """
SELECT r.id
FROM fd.photo_removals r
LEFT JOIN fd.member_guards g ON g.id = r.guard_id
WHERE r.state = 'asked'
  AND (r.guard_id IS NULL OR g.enforcement_status = 'held')
ORDER BY r.asked_at
LIMIT %s
"""

CLAIM = """
UPDATE fd.photo_removals
SET state = 'running', attempts = attempts + 1, started_at = now()
WHERE id = %s AND state = 'asked'
RETURNING id, member_id, asked_by, attempts
"""

RECORD_ORIGINAL = """
UPDATE fd.photo_removals
SET avatar_url = coalesce(avatar_url, %s), avatar_hash = coalesce(avatar_hash, %s)
WHERE id = %s
"""

STORE_EVIDENCE = """
INSERT INTO fd.photo_removal_evidence (removal_id, image, content_type, sha256)
VALUES (%s, %s, %s, %s)
ON CONFLICT (removal_id) DO NOTHING
"""

INSERT_REQUEST = """
INSERT INTO fd.photo_removals (member_id, asked_by, reason)
VALUES (%s, %s, %s)
ON CONFLICT (member_id) WHERE state IN ('asked', 'running') DO NOTHING
RETURNING id
"""

FINISH = "UPDATE fd.photo_removals SET state = %s, error = %s, finished_at = now() WHERE id = %s"

RETRY = "UPDATE fd.photo_removals SET state = 'asked', error = %s WHERE id = %s"

REFRESH_MEMBER = "UPDATE fd.member SET avatar_url = %s, avatar_hash = %s WHERE user_id = %s"

_lock = threading.Lock()


def allowed_image_url(url):
    parts = urlparse(url or "")
    return (parts.scheme == "https" and parts.hostname in IMAGE_HOSTS
            and not parts.username and parts.port in (None, 443))


class AllowedRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed_image_url(newurl):
            raise ValueError(f"image redirect not allowed: {urlparse(newurl).hostname}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def content_type_of(header):
    value = (header or "").split(";")[0].strip().lower()
    return value if value in IMAGE_TYPES else FALLBACK_TYPE


def fetch_image(url):
    if not allowed_image_url(url):
        raise ValueError(f"image host not allowed: {urlparse(url or '').hostname}")
    opener = urllib.request.build_opener(AllowedRedirects())
    request = urllib.request.Request(url, headers={"User-Agent": "nemo"})
    with opener.open(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
        body = response.read(MAX_IMAGE_BYTES + 1)
        content_type = content_type_of(response.headers.get("Content-Type"))
    if not body:
        raise ValueError("image is empty")
    if len(body) > MAX_IMAGE_BYTES:
        raise ValueError("image is over the size limit")
    return body, content_type


def image_url(profile):
    return next((profile[key] for key in IMAGE_KEYS if profile.get(key)), None)


def original_of(profile):
    avatar_hash = profile.get("avatar_hash") or None
    url = image_url(profile)
    if url is None:
        return Original(None, avatar_hash, None, None)
    image, content_type = fetch_image(url)
    return Original(url, avatar_hash, image, content_type)


def save_original(removal_id, original):
    with session() as conn:
        conn.execute(RECORD_ORIGINAL, (original.url, original.avatar_hash, removal_id))
        if original.image is not None:
            conn.execute(STORE_EVIDENCE, (
                removal_id, original.image, original.content_type,
                hashlib.sha256(original.image).hexdigest(),
            ))


def refresh_member(member_id, previous_hash):
    for _ in range(REFRESH_ATTEMPTS):
        time.sleep(REFRESH_DELAY_SECONDS)
        profile = (privileged.profile(member_id) or {}).get("profile") or {}
        current_hash = profile.get("avatar_hash")
        if current_hash and current_hash != previous_hash:
            with session() as conn:
                conn.execute(REFRESH_MEMBER, (profile.get("image_512") or None, current_hash, member_id))
            return True
    return False


def perform(removal):
    user = privileged.profile(removal.member_id)
    if user is None:
        return "profile lookup failed"

    try:
        original = original_of(user.get("profile") or {})
    except Exception as failure:
        return f"original not saved: {str(failure)[:200]}"
    save_original(removal.id, original)

    outcome = privileged.replace_photo(removal.member_id)
    if outcome != privileged.PHOTO_REPLACED:
        return outcome

    refresh_member(removal.member_id, original.avatar_hash)
    return None


def run(removal_id):
    with session() as conn:
        row = conn.execute(CLAIM, (removal_id,)).fetchone()
    if row is None:
        return False

    removal = Removal(*row)
    try:
        error = perform(removal)
    except Exception as failure:
        log.exception("nemo: photo removal %s raised", removal.id)
        error = f"failed: {str(failure)[:200]}"

    with session() as conn:
        if error is None:
            conn.execute(FINISH, (DONE, None, removal.id))
            audit.record(conn, ENTITY_TYPE, removal.id, "performed", removal.asked_by,
                         subject_user_id=removal.member_id,
                         after={"member_id": removal.member_id})
        elif removal.attempts >= GIVE_UP_AFTER:
            conn.execute(FINISH, (FAILED, error, removal.id))
        else:
            conn.execute(RETRY, (error, removal.id))

    log.info("nemo: photo removal %s for %s -> %s", removal.id, removal.member_id, error or DONE)
    return error is None


def queue_request(conn, member_id, reason, asked_by):
    if reason and len(reason) > MAX_REASON_LENGTH:
        return REASON_TOO_LONG

    row = conn.execute(INSERT_REQUEST, (member_id, asked_by, reason or None)).fetchone()
    if row is None:
        return ALREADY_QUEUED_ANSWER.format(member_id=member_id)

    audit.record(conn, ENTITY_TYPE, row[0], "queued", asked_by, subject_user_id=member_id,
                 after={"member_id": member_id})
    return QUEUED_ANSWER.format(member_id=member_id)


def drain():
    if not _lock.acquire(blocking=False):
        return 0
    try:
        with session() as conn:
            conn.execute(INTERRUPTED)
            conn.execute(CANCELLED, (DEACTIVATION_CANCELLED,))
            removal_ids = [row[0] for row in conn.execute(READY, (PER_PASS,)).fetchall()]
        return sum(1 for removal_id in removal_ids if run(removal_id))
    finally:
        _lock.release()
