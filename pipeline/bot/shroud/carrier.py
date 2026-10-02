import logging

from bot.core import blobs, case, evidence, faces, intake, outbox, session
from bot.core.whoami import bot_user_id
from bot.core.wording import to_member
from bot.shroud import intake_files

log = logging.getLogger("bot.shroud")

LOOK_BACK = 30

KEEP_FILE = """
INSERT INTO fd.intake_files
    (slack_file_id, name, mimetype, original_w, original_h,
     fetch_state, sha256, stored_key, stored_bytes, fetched_at)
VALUES (%s, %s, %s, %s, %s, 'stored', %s, %s, %s, now())
ON CONFLICT (slack_file_id) DO UPDATE SET last_seen_at = now()
RETURNING id
"""

LINK_FILE = """
INSERT INTO fd.intake_message_files (message_id, file_id, seq, mirrored_file_id, mirrored_at)
VALUES (%s, %s, %s, %s, now())
ON CONFLICT DO NOTHING
"""

FIRST_ANSWER_FOR = """
UPDATE fd.case_reports SET first_replied_at = now()
WHERE id = (SELECT report_id FROM fd.intake_conversations WHERE id = %s)
  AND first_replied_at IS NULL
"""


def shared_at(file, channel_id):
    shares = (file or {}).get("shares") or {}
    for kind in ("public", "private"):
        for room, entries in (shares.get(kind) or {}).items():
            if room == channel_id and entries:
                return entries[0].get("ts")
    return None


class Carrier:
    def __init__(self, client=None):
        self.client = client

    def taken(self, conversation_id, message_id, anonymous=True):
        opener = bot_user_id(self.client, "shroud")
        with session() as conn:
            already = case.existing(conn, conversation_id)
            case_id = case.open_case(conn, conversation_id, opener, anonymous)
            brought = evidence.promote(conn, case_id, conversation_id, opener)
            if already:
                case.wake(conn, case_id, opener)
        log.info("shroud: conversation %s is case %s", conversation_id, case_id)
        self.keep_attachments(conversation_id)
        if brought["threads"] or brought["messages"]:
            log.info(
                "shroud: case %s came with %s thread(s) and %s message(s)",
                case_id, brought["threads"], brought["messages"],
            )

        return case_id

    def keep_attachments(self, conversation_id):
        try:
            return intake_files.drain(self.client.token)
        except Exception:
            log.exception(
                "shroud: could not keep the files of conversation %s, they stay pending",
                conversation_id,
            )
            return 0

    def deliver(self, conversation_id=None):
        with session() as conn:
            queue = outbox.waiting(conn, conversation_id)

        sent = 0
        for queued in queue:
            with session() as conn:
                if self.hand_over(conn, queued):
                    sent += 1

        if sent:
            log.info("shroud: sent %s queued message(s)", sent)

        return sent

    def hand_over(self, conn, queued):
        if queued.closed_at:
            outbox.stumbled(conn, queued.id, "the conversation is closed", True)
            log.info("shroud: outbox %s is for a closed conversation", queued.id)
            return False

        words = (queued.body or "").strip()
        held = queued.files or []
        if not words and not held:
            outbox.stumbled(conn, queued.id, "there was nothing to send", True)
            log.warning("shroud: outbox %s had neither words nor a file", queued.id)
            return False

        try:
            said_ts = self.say_it(queued) if words else None
            carried = self.hand_out_files(conn, queued)
        except Exception as failure:
            outbox.stumbled(conn, queued.id, failure, queued.last_try)
            log.warning("shroud: outbox %s did not go: %s", queued.id, failure)
            return False

        if words and said_ts is None:
            outbox.stumbled(conn, queued.id, "slack took the words but named no message", True)
            return False

        ts = said_ts or next((one["ts"] for one in carried if one.get("ts")), None)
        if ts is None:
            log.info("shroud: slack named no message for outbox %s, keeping it anyway", queued.id)

        message_id, _ = intake.record(
            conn,
            {
                "channel": queued.channel_id,
                "ts": ts,
                "thread_ts": queued.thread_ts,
                "text": queued.body,
            },
            direction="outbound",
            sent_by=queued.requested_by,
        )
        self.keep_what_went(conn, message_id, carried)
        outbox.sent(conn, queued.id, message_id)
        if queued.kind == "reply":
            conn.execute(FIRST_ANSWER_FOR, (queued.conversation_id,))
        return True

    def say_it(self, queued):
        posted = self.client.chat_postMessage(
            channel=queued.channel_id,
            thread_ts=queued.thread_ts,
            text=to_member(queued.body),
            unfurl_links=False,
            unfurl_media=False,
            **self.wearing(queued),
        )
        return posted.get("ts")

    def keep_what_went(self, conn, message_id, carried):
        for seq, one in enumerate(carried):
            file_id = conn.execute(
                KEEP_FILE,
                (one.get("id"), one.get("name"), one.get("mimetype"),
                 one.get("original_w"), one.get("original_h"),
                 one["sha256"], one["sha256"], one.get("size")),
            ).fetchone()[0]
            conn.execute(LINK_FILE, (message_id, file_id, seq, one.get("id") or "sent"))

    def hand_out_files(self, conn, queued):
        carried = []
        for one in queued.files or []:
            body, kept_type = blobs.body_of(conn, one.get("sha256"))
            if body is None:
                log.warning("shroud: outbox %s lost the bytes of %s", queued.id, one.get("name"))
                continue

            answer = self.client.files_upload_v2(
                channel=queued.channel_id,
                thread_ts=queued.thread_ts,
                content=body,
                filename=one.get("name") or "file",
            )
            sent = (answer.get("files") or [{}])[0]
            carried.append({
                "sha256": one["sha256"],
                "name": one.get("name"),
                "mimetype": sent.get("mimetype") or one.get("mimetype") or kept_type,
                "original_w": one.get("original_w") or sent.get("original_w"),
                "original_h": one.get("original_h") or sent.get("original_h"),
                "size": len(body),
                "id": sent.get("id"),
                "ts": self.where_it_landed(sent, queued.channel_id, queued.thread_ts),
            })
        return carried

    def where_it_landed(self, file, channel_id, thread_ts):
        ts = shared_at(file, channel_id)
        if ts:
            return ts

        file_id = file.get("id")
        if not file_id:
            return None

        try:
            found = self.client.files_info(file=file_id)
            ts = shared_at(found.get("file"), channel_id)
            if ts:
                return ts
        except Exception as failure:
            log.info("shroud: files.info would not place %s: %s", file_id, failure)

        return self.found_in_thread(file_id, channel_id, thread_ts)

    def found_in_thread(self, file_id, channel_id, thread_ts):
        try:
            answer = self.client.conversations_replies(
                channel=channel_id, ts=thread_ts, limit=LOOK_BACK
            )
        except Exception as failure:
            log.warning("shroud: could not read the thread to place %s: %s", file_id, failure)
            return None

        for message in reversed(answer.get("messages") or []):
            for one in message.get("files") or []:
                if one.get("id") == file_id:
                    return message.get("ts")
        return None

    def wearing(self, queued):
        if queued.mode != "signed" or not queued.requested_by:
            return {}

        return {
            "username": faces.name(queued.requested_by) or f"@{queued.requested_by}",
            "icon_url": faces.icon_url(queued.requested_by),
            "metadata": {
                "event_type": "nemo_message",
                "event_payload": {"source_user_id": queued.requested_by},
            },
        }
