import logging
import urllib.error
import urllib.request

from bot.core import blobs

TIMEOUT = 30

log = logging.getLogger("bot.nemo")

TO_SHARE = """
SELECT mf.file_id, f.name, f.mimetype, f.stored_key, f.original_w
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
WHERE mf.message_id = %s AND mf.mirrored_at IS NULL AND f.fetch_state = 'stored'
ORDER BY mf.seq
"""


def alt_text(name, mimetype):
    if (mimetype or "").startswith("image/"):
        return f"screenshot the reporter sent, {name}"
    return name


def share(client, conn, message_id, channel_id, thread_ts):
    rows = conn.execute(TO_SHARE, (message_id,)).fetchall()
    sent = 0

    for file_id, name, mimetype, sha, width in rows:
        body, kept_type = blobs.body_of(conn, sha)
        if body is None:
            log.warning("nemo: file %s says stored but has no bytes", file_id)
            continue

        try:
            answer = client.files_upload_v2(
                content=body,
                filename=name or f"{sha[:12]}",
                title=name,
                alt_txt=alt_text(name, mimetype or kept_type) if width else None,
                channel=channel_id,
                thread_ts=thread_ts,
            )
        except Exception:
            log.exception("nemo: could not carry file %s into the thread", file_id)
            continue

        uploaded = (answer.get("files") or [{}])[0].get("id")
        conn.execute(
            "UPDATE fd.intake_message_files SET mirrored_file_id = %s, mirrored_at = now() "
            "WHERE message_id = %s AND file_id = %s AND mirrored_at IS NULL",
            (uploaded, message_id, file_id),
        )
        sent += 1

    if sent:
        log.info("nemo: carried %d file(s) into the firehouse", sent)
    return sent


def fetch(url, token, limit):
    if not blobs.slack_url(url):
        log.warning("nemo: %s is not an https slack url, not asking for it", url)
        return None

    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as answer:
            body = answer.read(limit + 1)
            return body if len(body) <= limit else None
    except (urllib.error.URLError, TimeoutError, OSError) as trouble:
        log.warning("nemo: could not fetch %s: %s", url, trouble)
        return None
