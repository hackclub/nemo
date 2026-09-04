import hashlib
import os
from urllib.parse import urlparse

DEFAULT_CAP = 25 * 1024 * 1024
HTML = ("text/html", "application/xhtml+xml")
SLACK_HOSTS = (".slack.com", ".slack-edge.com", ".slack-files.com")


def slack_url(url):
    try:
        seen = urlparse(url or "")
    except ValueError:
        return False
    host = (seen.hostname or "").lower()
    return seen.scheme == "https" and (
        host == "slack.com" or host.endswith(SLACK_HOSTS)
    )

PENDING = """
SELECT id, slack_file_id, url_private, size_bytes, mimetype
FROM fd.intake_files
WHERE fetch_state = 'pending' AND url_private IS NOT NULL
ORDER BY first_seen_at, id
LIMIT %s
"""


def cap():
    raw = os.environ.get("INTAKE_FILE_MAX_BYTES")
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_CAP
    return value if value > 0 else DEFAULT_CAP


def verdict(status, content_type, size, limit=None):
    limit = cap() if limit is None else limit
    if status in (401, 403):
        return "refused", f"slack answered {status}, the token cannot read this file"
    if status == 404 or status == 410:
        return "gone", None
    if status != 200:
        return "failed", f"slack answered {status}"
    if (content_type or "").split(";")[0].strip().lower() in HTML:
        return "refused", "slack returned a web page instead of the file"
    if size is not None and size > limit:
        return "too_large", f"{size} bytes is over the {limit} byte limit"
    if not size:
        return "failed", "slack returned an empty body"
    return "stored", None


def too_big_to_ask(size, limit=None):
    limit = cap() if limit is None else limit
    return bool(size) and size > limit


def waiting(conn, limit=20):
    return conn.execute(PENDING, (limit,)).fetchall()


def keep(conn, file_id, body, mimetype):
    sha = hashlib.sha256(body).hexdigest()
    conn.execute(
        "INSERT INTO fd.intake_file_blobs (sha256, body, size_bytes, mimetype) "
        "VALUES (%s, %s, %s, %s) ON CONFLICT (sha256) DO NOTHING",
        (sha, body, len(body), mimetype),
    )
    conn.execute(
        "UPDATE fd.intake_files SET fetch_state = 'stored', sha256 = %s, stored_key = %s, "
        "stored_bytes = %s, fetched_at = now(), fetch_error = NULL, "
        "fetch_attempts = fetch_attempts + 1 WHERE id = %s",
        (sha, sha, len(body), file_id),
    )
    return sha


def give_up(conn, file_id, state, error):
    conn.execute(
        "UPDATE fd.intake_files SET fetch_state = %s, fetch_error = %s, "
        "fetch_attempts = fetch_attempts + 1, fetched_at = now() WHERE id = %s",
        (state, error, file_id),
    )


def purge(conn, file_id, purged_by):
    conn.execute(
        "UPDATE fd.intake_files SET fetch_state = 'purged', stored_key = NULL, "
        "stored_bytes = NULL, purged_at = now(), purged_by = %s "
        "WHERE id = %s AND purged_at IS NULL",
        (purged_by, file_id),
    )
    return conn.execute(
        "DELETE FROM fd.intake_file_blobs b WHERE NOT EXISTS ("
        "  SELECT 1 FROM fd.intake_files f WHERE f.stored_key = b.sha256"
        ") RETURNING sha256"
    ).rowcount


def body_of(conn, sha):
    row = conn.execute(
        "SELECT body, mimetype FROM fd.intake_file_blobs WHERE sha256 = %s", (sha,)
    ).fetchone()
    return (bytes(row[0]), row[1]) if row else (None, None)
