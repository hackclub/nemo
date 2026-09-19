import logging

from bot.core import blobs, case, evidence, faces, intake, outbox, session
from bot.core.whoami import bot_user_id
from bot.core.wording import to_member
from bot.shroud import intake_files

log = logging.getLogger("bot.shroud")

FIRST_ANSWER_FOR = """
UPDATE fd.case_reports SET first_replied_at = now()
WHERE id = (SELECT report_id FROM fd.intake_conversations WHERE id = %s)
  AND first_replied_at IS NULL
"""


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

        try:
            posted = self.client.chat_postMessage(
                channel=queued.channel_id,
                thread_ts=queued.thread_ts,
                text=to_member(queued.body),
                unfurl_links=False,
                unfurl_media=False,
                **self.wearing(queued),
            )
        except Exception as failure:
            outbox.stumbled(conn, queued.id, failure, queued.last_try)
            log.warning("shroud: outbox %s did not go: %s", queued.id, failure)
            return False

        message_id, _ = intake.record(
            conn,
            {
                "channel": queued.channel_id,
                "ts": posted["ts"],
                "thread_ts": queued.thread_ts,
                "text": to_member(queued.body),
            },
            direction="outbound",
            sent_by=queued.requested_by,
        )
        outbox.sent(conn, queued.id, message_id)
        if queued.kind == "reply":
            conn.execute(FIRST_ANSWER_FOR, (queued.conversation_id,))
        self.hand_out_files(conn, queued)
        return True

    def hand_out_files(self, conn, queued):
        carried = 0
        for one in queued.files or []:
            body, _ = blobs.body_of(conn, one.get("sha256"))
            if body is None:
                log.warning("shroud: outbox %s lost the bytes of %s", queued.id, one.get("name"))
                continue
            try:
                self.client.files_upload_v2(
                    channel=queued.channel_id,
                    thread_ts=queued.thread_ts,
                    content=body,
                    filename=one.get("name") or "file",
                )
                carried += 1
            except Exception as failure:
                log.warning("shroud: could not hand over %s: %s", one.get("name"), failure)
        return carried

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
