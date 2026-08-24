from psycopg.types.json import Jsonb

from bot.engine import parse
from bot.engine.identity import ensure_member


def root_ts(event):
    return event.get("thread_ts") or event.get("ts")


FIND = """
SELECT id FROM fd.intake_conversations WHERE channel_id = %s AND thread_ts = %s
"""


def conversation(conn, channel_id, thread_ts, member_user_id=None):
    ensure_member(conn, member_user_id)
    row = conn.execute(FIND, (channel_id, thread_ts)).fetchone()
    if row:
        return row[0]

    conn.execute(
        "INSERT INTO fd.intake_conversations (channel_id, thread_ts, member_user_id) "
        "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
        (channel_id, thread_ts, member_user_id),
    )
    return conn.execute(FIND, (channel_id, thread_ts)).fetchone()[0]


def close(conn, conversation_id, closed_by):
    conn.execute(
        "UPDATE fd.intake_conversations SET closed_at = now(), closed_by = %s "
        "WHERE id = %s AND closed_at IS NULL",
        (closed_by, conversation_id),
    )


def record(conn, event, direction="inbound", sent_by=None):
    channel_id = event["channel"]
    ts = event["ts"]
    author = event.get("user") if direction == "inbound" else None
    ensure_member(conn, author)

    convo = conversation(conn, channel_id, root_ts(event), author)
    body = event.get("text")
    blocks = event.get("blocks")
    attachments = event.get("attachments")

    row = conn.execute(
        "INSERT INTO fd.intake_messages "
        "(conversation_id, channel_id, ts, thread_ts, client_msg_id, direction, "
        " author_user_id, author_bot_id, sent_by, subtype, body, blocks, attachments, raw, posted_at) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
        "ON CONFLICT (channel_id, ts) DO UPDATE SET last_seen_at = now() "
        "RETURNING id, (xmax = 0) AS inserted",
        (
            convo,
            channel_id,
            ts,
            event.get("thread_ts"),
            event.get("client_msg_id"),
            direction,
            author,
            event.get("bot_id"),
            sent_by,
            event.get("subtype"),
            body,
            Jsonb(blocks) if blocks else None,
            Jsonb(attachments) if attachments else None,
            Jsonb(event),
            parse.posted_at(ts),
        ),
    ).fetchone()
    message_id, fresh = row[0], row[1]

    if not fresh:
        return message_id, False

    conn.execute(
        "INSERT INTO fd.intake_revisions (message_id, seq, body, blocks, attachments, digest) "
        "VALUES (%s, 0, %s, %s, %s, %s) ON CONFLICT (message_id, seq) DO NOTHING",
        (
            message_id,
            body,
            Jsonb(blocks) if blocks else None,
            Jsonb(attachments) if attachments else None,
            parse.digest(body, blocks, attachments),
        ),
    )
    conn.execute(
        "UPDATE fd.intake_conversations SET last_message_at = %s WHERE id = %s",
        (parse.posted_at(ts), convo),
    )

    attach(conn, message_id, event)
    return message_id, True


def attach(conn, message_id, event):
    for share in parse.shares(event):
        conn.execute(
            "INSERT INTO fd.intake_shares "
            "(message_id, kind, source_channel_id, source_channel_name, source_ts, "
            " source_thread_ts, source_author_user_id, source_body, permalink, "
            " is_reachable, raw) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
            (
                message_id,
                share["kind"],
                share["source_channel_id"],
                share["source_channel_name"],
                share["source_ts"],
                share["source_thread_ts"],
                share["source_author_user_id"],
                share["source_body"],
                share["permalink"],
                share.get("is_reachable", False),
                Jsonb(share["raw"]) if share["raw"] else None,
            ),
        )

    for seq, item in enumerate(parse.files(event)):
        file_id = conn.execute(
            "INSERT INTO fd.intake_files "
            "(slack_file_id, name, title, mimetype, filetype, mode, size_bytes, "
            " original_w, original_h, is_external, external_type, external_url, permalink, "
            " url_private, uploaded_by, is_tombstoned, is_hidden_by_limit, fetch_state, "
            " fetch_error, created_at) "
            "VALUES (%(slack_file_id)s, %(name)s, %(title)s, %(mimetype)s, %(filetype)s, "
            " %(mode)s, %(size_bytes)s, %(original_w)s, %(original_h)s, %(is_external)s, "
            " %(external_type)s, %(external_url)s, %(permalink)s, %(url_private)s, "
            " %(uploaded_by)s, %(is_tombstoned)s, %(is_hidden_by_limit)s, %(fetch_state)s, "
            " %(fetch_error)s, %(created_at)s) "
            "ON CONFLICT (slack_file_id) DO UPDATE SET last_seen_at = now() "
            "RETURNING id",
            item,
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO fd.intake_message_files (message_id, file_id, seq) "
            "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
            (message_id, file_id, seq),
        )


def edit(conn, channel_id, message):
    ts = message.get("ts")
    row = conn.execute(
        "SELECT m.id, m.revision, r.digest FROM fd.intake_messages m "
        "LEFT JOIN fd.intake_revisions r ON r.message_id = m.id AND r.seq = m.revision "
        "WHERE m.channel_id = %s AND m.ts = %s",
        (channel_id, ts),
    ).fetchone()
    if not row:
        return None
    message_id, revision, latest = row

    body = message.get("text")
    blocks = message.get("blocks")
    attachments = message.get("attachments")
    fingerprint = parse.digest(body, blocks, attachments)
    if fingerprint == latest:
        return None

    edited = message.get("edited") or {}
    edited_at = parse.posted_at(edited["ts"]) if edited.get("ts") else None
    conn.execute(
        "INSERT INTO fd.intake_revisions "
        "(message_id, seq, body, blocks, attachments, digest, edited_at, edited_by) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
        (
            message_id,
            revision + 1,
            body,
            Jsonb(blocks) if blocks else None,
            Jsonb(attachments) if attachments else None,
            fingerprint,
            edited_at,
            edited.get("user"),
        ),
    )
    conn.execute(
        "UPDATE fd.intake_messages SET body = %s, blocks = %s, attachments = %s, "
        "revision = %s, edited_at = %s, edited_by = %s, last_seen_at = now() WHERE id = %s",
        (
            body,
            Jsonb(blocks) if blocks else None,
            Jsonb(attachments) if attachments else None,
            revision + 1,
            edited_at,
            edited.get("user"),
            message_id,
        ),
    )
    attach(conn, message_id, message)
    return message_id


def delete(conn, channel_id, deleted_ts):
    row = conn.execute(
        "UPDATE fd.intake_messages SET deleted_at = now(), last_seen_at = now() "
        "WHERE channel_id = %s AND ts = %s AND deleted_at IS NULL RETURNING id",
        (channel_id, deleted_ts),
    ).fetchone()
    return row[0] if row else None
