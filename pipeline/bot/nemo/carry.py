import logging
import urllib.error
import urllib.request

from bot.core import blobs

TIMEOUT = 30
IN_BLOCKS = ("image/png", "image/jpeg", "image/jpg", "image/gif")

log = logging.getLogger("bot.nemo")

TO_SHARE = """
SELECT mf.file_id, f.name, f.mimetype, f.stored_key, f.original_w
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
WHERE mf.message_id = %s AND mf.mirrored_at IS NULL AND f.fetch_state = 'stored'
ORDER BY mf.seq
"""

MIRRORED = """
UPDATE fd.intake_message_files SET mirrored_file_id = %s, mirrored_at = now()
WHERE message_id = %s AND file_id = %s AND mirrored_at IS NULL
"""


def alt_text(name, mimetype):
    if (mimetype or "").startswith("image/"):
        return f"screenshot the reporter sent, {name}"
    return name


def shows_inline(mimetype):
    return (mimetype or "").lower() in IN_BLOCKS


def held_in_slack(client, name, body, channel_id=None, thread_ts=None):
    """Uploaded with no channel the file stays private, which is what a block wants."""
    where = {"channel": channel_id, "thread_ts": thread_ts} if channel_id else {}
    answer = client.files_upload_v2(content=body, filename=name, title=name, **where)
    return (answer.get("files") or [{}])[0].get("id")


def gather(conn, message_id):
    inline, on_their_own = [], []
    for file_id, name, mimetype, sha, _ in conn.execute(TO_SHARE, (message_id,)).fetchall():
        body, kept_type = blobs.body_of(conn, sha)
        if body is None:
            log.warning("nemo: file %s says stored but has no bytes", file_id)
            continue
        kind = mimetype or kept_type
        held = (file_id, name or f"{sha[:12]}", kind, body)
        (inline if shows_inline(kind) else on_their_own).append(held)
    return inline, on_their_own


def share(client, conn, message_id, channel_id, thread_ts, wearing=None, words=None):
    """The reporter's words and pictures go up together, wearing the reporter's face."""
    inline, on_their_own = gather(conn, message_id)
    said = (words or "").strip()
    if not inline and not on_their_own and not said:
        return None

    ts = post(
        client, conn, message_id, channel_id, thread_ts, inline, said, on_their_own, wearing or {}
    )

    for file_id, name, _, body in on_their_own:
        try:
            uploaded = held_in_slack(client, name, body, channel_id, thread_ts)
        except Exception:
            log.exception("nemo: could not carry file %s into the thread", file_id)
            continue
        if uploaded:
            conn.execute(MIRRORED, (uploaded, message_id, file_id))

    return ts


def post(client, conn, message_id, channel_id, thread_ts, inline, said, alongside, wearing):
    kept = []
    for file_id, name, kind, body in inline:
        try:
            uploaded = held_in_slack(client, name, body)
        except Exception:
            log.exception("nemo: could not keep file %s for the thread", file_id)
            continue
        if uploaded:
            kept.append((file_id, name, kind, uploaded))

    blocks = []
    if said:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": said}})
    for _, name, kind, uploaded in kept:
        blocks.append({
            "type": "image",
            "slack_file": {"id": uploaded},
            "alt_text": alt_text(name, kind),
        })
    if not blocks and alongside:
        blocks.append(named(alongside))

    if not blocks:
        return None

    sent = client.chat_postMessage(
        channel=channel_id,
        thread_ts=thread_ts,
        text=said or told(kept or alongside),
        blocks=blocks,
        unfurl_links=False,
        unfurl_media=False,
        **wearing,
    )
    ts = sent["ts"]
    for file_id, _, _, uploaded in kept:
        conn.execute(MIRRORED, (uploaded, message_id, file_id))
    if kept:
        log.info("nemo: carried %d file(s) into the firehouse", len(kept))
    return ts


def named(alongside):
    names = ", ".join(one[1] for one in alongside)
    return {"type": "section", "text": {"type": "mrkdwn", "text": f":paperclip: {names}"}}


def told(kept):
    if len(kept) == 1:
        return kept[0][1]
    return f"{len(kept)} attachments"


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
