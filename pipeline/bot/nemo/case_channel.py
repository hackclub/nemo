import logging
import time

from psycopg.errors import LockNotAvailable

from bot.core import audit, blobs, intake, outbox, parse, session
from bot.nemo import announce, answer, attachments, case_actions, case_cards, channel, case_queue

log = logging.getLogger("bot.nemo")

LOCK_RETRY_DELAYS_SECONDS = (0.5, 2.0)

REPORT_CONVERSATION = """
SELECT c.id, c.channel_id, c.thread_ts, c.closed_at, c.report_id, c.closed_by
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
WHERE m.mirrored_ts = %s
"""

CLOSED_REFUSAL = "Not sent. The reporter's conversation is closed."
CLOSED_REFUSALS = {intake.TRUSTED_SENDER: "Not sent. Replies are disabled for trusted senders."}

MARK_FIRST_REPLY = """
UPDATE fd.case_reports SET first_replied_at = now()
WHERE id = %s AND first_replied_at IS NULL
"""


class CaseChannel:
    def __init__(self, client=None):
        self.client = client

    def refresh_card(self, case_id):
        with session() as conn:
            return channel.refresh_card(self.client, conn, case_id)

    def run_step(self, work, case_id):
        for delay in (*LOCK_RETRY_DELAYS_SECONDS, None):
            try:
                with session() as conn:
                    return work(self.client, conn, case_id)
            except LockNotAvailable:
                if delay is None:
                    raise
                time.sleep(delay)

    def sync_case(self, case_id):
        card = None
        for name, work in (
            ("case card", channel.refresh_card),
            ("follow-ups", channel.post_follow_ups),
            ("reopen prompt", channel.post_reopen_prompt),
            ("unfurls", channel.post_unfurls),
            ("files", channel.post_files),
            ("edit notices", channel.post_edit_notices),
            ("queue card", case_queue.post_missing_card),
            ("thread card", case_queue.refresh_card),
            ("case card posts", case_cards.refresh),
        ):
            try:
                result = self.run_step(work, case_id)
                if name == "case card":
                    card = result
            except Exception:
                log.exception("nemo: case %s could not have its %s seen to", case_id, name)
        self.announce_fire_engine()
        return card

    def mirror(self, case_id):
        with session() as conn:
            return channel.mirror(self.client, conn, case_id)

    def add_reaction(self, at, emoji):
        if at is None:
            return
        channel_id, ts = at
        try:
            self.client.reactions_add(channel=channel_id, timestamp=ts, name=emoji)
        except Exception as failure:
            if not any(code in str(failure) for code in channel.IGNORED_REACTION_ERRORS):
                log.warning("nemo: could not mark %s with %s: %s", ts, emoji, failure)

    def refuse_reply(self, at, sent_by, message):
        self.add_reaction(at, answer.FAILED_REACTION)
        if at is None:
            return None
        channel_id, ts = at
        try:
            self.client.chat_postEphemeral(
                channel=channel_id, user=sent_by, thread_ts=ts, text=message
            )
        except Exception as failure:
            log.warning("nemo: could not say why it did not send: %s", failure)
        return None

    def queue_reply(self, thread_ts, text, sent_by, signed=True, files=(), at=None):
        if not (text or "").strip() and not files:
            return None

        with session() as conn:
            row = conn.execute(REPORT_CONVERSATION, (thread_ts,)).fetchone()
        if not row:
            log.info("nemo: thread %s is not a report thread", thread_ts)
            return None
        conversation_id, _channel_id, _member_thread_ts, closed_at, report_id, closed_by = row
        if closed_at:
            log.info("nemo: conversation %s is closed, not queueing", conversation_id)
            return self.refuse_reply(at, sent_by, CLOSED_REFUSALS.get(closed_by, CLOSED_REFUSAL))

        with session() as conn:
            stored_files = self.store_outgoing_files(conn, files)
            queued_id = outbox.queue(
                conn,
                conversation_id,
                "reply",
                text,
                sent_by,
                mode="signed" if signed else "body",
                files=stored_files,
                requested_in=at[0] if at else None,
                requested_at=at[1] if at else None,
            )
            outbox.claim_mirror(conn, queued_id)
            outbox.mark_mirrored(conn, queued_id, None, "user")
            if report_id:
                conn.execute(MARK_FIRST_REPLY, (report_id,))
                audit.record(
                    conn,
                    "report",
                    report_id,
                    "answered",
                    sent_by,
                    after={"mode": "signed" if signed else "body", "source": "nemo"},
                )

        log.info(
            "nemo: queued a %s answer for conversation %s as outbox %s",
            "signed" if signed else "unsigned", conversation_id, queued_id,
        )
        return queued_id

    def store_outgoing_files(self, conn, files):
        stored_files = []
        for item in files or []:
            url = item.get("url_private_download") or item.get("url_private")
            name = item.get("name") or item.get("id") or "file"
            if not url:
                continue
            body = attachments.fetch(url, self.client.token, blobs.cap())
            if body is None:
                log.warning("nemo: %s could not be kept, it is not going out", name)
                continue
            stored_files.append({
                "name": name,
                "mimetype": item.get("mimetype"),
                "original_w": parse.to_int(item.get("original_w")),
                "original_h": parse.to_int(item.get("original_h")),
                "sha256": blobs.insert_blob(conn, body, item.get("mimetype")),
            })
        return stored_files

    def mirror_outbox_replies(self, case_id=None):
        with session() as conn:
            rows = outbox.to_mirror(conn, case_id)

        mirrored_count = 0
        for outbox_id, body, mode, requested_by, forwarded_ts, card_channel_id in rows:
            with session() as conn:
                if not outbox.claim_mirror(conn, outbox_id):
                    continue
                at = channel.post_outbox_reply(
                    self.client, forwarded_ts, requested_by, body, mode == "signed",
                    channel.channel_or_firehouse(card_channel_id, None, conn),
                )
                if at is None:
                    outbox.release_mirror(conn, outbox_id)
                    continue
                outbox.mark_mirrored(conn, outbox_id, at[1], "nemo")
                mirrored_count += 1

        if mirrored_count:
            log.info("nemo: echoed %s queued message(s) into case threads", mirrored_count)
        self.post_pending_resolutions()
        return mirrored_count

    def announce_fire_engine(self):
        try:
            with session() as conn:
                return announce.announce(self.client, conn)
        except Exception:
            log.exception("nemo: fire engine changes could not be told to their threads")
            return 0

    def post_pending_resolutions(self):
        with session() as conn:
            case_ids = case_actions.pending_resolution_logs(conn)

        for case_id in case_ids:
            with session() as conn:
                due = case_actions.resolution_log_due(conn, case_id)
                if due is None:
                    continue
                by, resolution, member_note = due
                channel.post_resolution_log(
                    self.client, conn, case_id, resolution, member_note, by,
                    case_actions.resolution_log_actions(conn, case_id),
                )
                log.info("nemo: case %s heard it was resolved after the reporter did", case_id)

    def mark_outbox_results(self):
        with session() as conn:
            pending = outbox.pending_reactions(conn)

        for outbox_id, channel_id, ts, failed_at, error, message_id in pending:
            target_channel_id = channel_id or channel.firehouse_channel()
            if not target_channel_id:
                continue
            self.add_reaction((target_channel_id, ts), answer.FAILED_REACTION if failed_at else answer.SENT_REACTION)
            if failed_at:
                self.post_refusal(target_channel_id, ts, error)
            with session() as conn:
                if message_id and not failed_at:
                    channel.read_links(self.client, conn, message_id)
                outbox.mark_reacted(conn, outbox_id)

        return len(pending)

    def post_refusal(self, channel_id, ts, error):
        try:
            self.client.chat_postMessage(
                channel=channel_id,
                thread_ts=ts,
                text=f"Not delivered: {error or 'Send failed'}",
                unfurl_links=False,
            )
        except Exception as failure:
            log.warning("nemo: could not say why %s did not go: %s", ts, failure)
