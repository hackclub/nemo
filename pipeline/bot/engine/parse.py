import hashlib
import json
import re
from datetime import datetime, timezone

ARCHIVE_LINK = re.compile(
    r"https://[a-zA-Z0-9._-]+\.slack\.com/archives/([A-Z][A-Z0-9]+)/p(\d{10})(\d{6})"
)


def posted_at(ts):
    return datetime.fromtimestamp(float(ts), tz=timezone.utc)


def digest(body, blocks, attachments):
    payload = json.dumps(
        [body or "", blocks or [], attachments or []],
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def link_target(url):
    found = ARCHIVE_LINK.search(url or "")
    if not found:
        return None
    channel_id, seconds, micros = found.groups()
    return channel_id, f"{seconds}.{micros}"


def shares(event):
    out = []
    seen = set()

    for attachment in event.get("attachments") or []:
        if not isinstance(attachment, dict):
            continue
        url = (
            attachment.get("permalink")
            or attachment.get("from_url")
            or attachment.get("title_link")
        )
        target = link_target(url)
        forwarded = bool(attachment.get("is_share"))
        unfurled = bool(attachment.get("is_msg_unfurl"))
        if not (forwarded or unfurled or target):
            continue

        channel_id = attachment.get("channel_id") or (target[0] if target else None)
        ts = attachment.get("ts") or (target[1] if target else None)
        if not url and not (channel_id and ts):
            continue

        key = (channel_id, ts, url)
        if key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "kind": "forward" if forwarded else "unfurl",
                "source_channel_id": channel_id,
                "source_channel_name": attachment.get("channel_name"),
                "source_ts": str(ts) if ts else None,
                "source_thread_ts": attachment.get("thread_ts"),
                "source_author_user_id": attachment.get("author_id"),
                "source_body": attachment.get("text") or attachment.get("fallback"),
                "permalink": url,
                "raw": attachment,
            }
        )

    for url in ARCHIVE_LINK.findall(event.get("text") or ""):
        channel_id, ts = url[0], f"{url[1]}.{url[2]}"
        if any(s["source_channel_id"] == channel_id and s["source_ts"] == ts for s in out):
            continue
        key = (channel_id, ts, None)
        if key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "kind": "link",
                "source_channel_id": channel_id,
                "source_channel_name": None,
                "source_ts": ts,
                "source_thread_ts": None,
                "source_author_user_id": None,
                "source_body": None,
                "permalink": None,
                "raw": None,
            }
        )

    return out


def files(event):
    out = []
    seen = set()
    for entry in event.get("files") or []:
        if not isinstance(entry, dict) or not entry.get("id"):
            continue
        if entry["id"] in seen:
            continue
        seen.add(entry["id"])

        mode = entry.get("mode")
        external = bool(entry.get("is_external")) or mode == "external"
        tombstoned = bool(entry.get("is_tombstoned")) or mode == "tombstone"
        hidden = bool(entry.get("is_hidden_by_limit"))

        if tombstoned or hidden:
            state, error = "gone", None
        elif external or not entry.get("url_private"):
            state, error = "skipped", None
        else:
            state, error = "pending", None

        created = entry.get("created")
        out.append(
            {
                "slack_file_id": entry["id"],
                "name": entry.get("name"),
                "title": entry.get("title"),
                "mimetype": entry.get("mimetype"),
                "filetype": entry.get("filetype"),
                "mode": mode,
                "size_bytes": entry.get("size"),
                "original_w": _int(entry.get("original_w")),
                "original_h": _int(entry.get("original_h")),
                "is_external": external,
                "external_type": entry.get("external_type"),
                "external_url": entry.get("external_url"),
                "permalink": entry.get("permalink"),
                "url_private": entry.get("url_private"),
                "uploaded_by": entry.get("user"),
                "is_tombstoned": tombstoned,
                "is_hidden_by_limit": hidden,
                "fetch_state": state,
                "fetch_error": error,
                "created_at": posted_at(created) if created else None,
            }
        )
    return out


def _int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
