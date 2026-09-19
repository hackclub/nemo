import logging

from bot.engine import audit, case, evidence, faces, intake, outbox, session
from bot.engine import files as store
from bot.engine.whoami import bot_user_id
from bot.nemo import answer, channel
from bot.nemo import files as carry
from bot.nemo.cards import report as cards
from bot.shroud import files as intake_files

log = logging.getLogger("bot.relay")

WHO_TO_REACH = """
SELECT c.id, c.channel_id, c.thread_ts, c.closed_at, c.report_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
WHERE m.mirrored_ts = %s
"""

FIRST_ANSWER = """
UPDATE fd.case_reports SET first_replied_at = now()
WHERE id = %s AND first_replied_at IS NULL
"""

FIRST_ANSWER_FOR = """
UPDATE fd.case_reports SET first_replied_at = now()
WHERE id = (SELECT report_id FROM fd.intake_conversations WHERE id = %s)
  AND first_replied_at IS NULL
"""

LINKED = """
SELECT 1 FROM fd.staff_slack WHERE staff_user_id = %s AND revoked_at IS NULL
"""

class Relay:
    def __init__(self, shroud_client=None, nemo_client=None):
        self.shroud_client = shroud_client
        self.nemo_client = nemo_client

    def taken(self, conversation_id, message_id, anonymous=True):
        opener = bot_user_id(self.shroud_client, "shroud") if self.shroud_client else None
        with session() as conn:
            already = case.existing(conn, conversation_id)
            case_id = case.open_case(conn, conversation_id, opener, anonymous)
            brought = evidence.promote(conn, case_id, conversation_id, opener)
            if already:
                case.wake(conn, case_id, opener)
        log.info("relay: conversation %s is case %s", conversation_id, case_id)
        self.keep_attachments(conversation_id)
        if brought["threads"] or brought["messages"]:
            log.info(
                "relay: case %s came with %s thread(s) and %s message(s)",
                case_id, brought["threads"], brought["messages"],
            )

        return case_id

    def keep_attachments(self, conversation_id):
        if self.shroud_client is None:
            log.warning(
                "relay: shroud is not running, conversation %s keeps its files pending",
                conversation_id,
            )
            return 0
        try:
            return intake_files.drain(self.shroud_client.token)
        except Exception:
            log.exception(
                "relay: could not keep the files of conversation %s, they stay pending",
                conversation_id,
            )
            return 0

    def redraw(self, case_id):
        if self.nemo_client is None:
            return None
        with session() as conn:
            return channel.redraw(self.nemo_client, conn, case_id)

    def caught_up(self, case_id):
        if self.nemo_client is None:
            return None
        with session() as conn:
            drawn = channel.redraw(self.nemo_client, conn, case_id)
            channel.tell_the_wake(self.nemo_client, conn, case_id)
            channel.carry_follow_ups(self.nemo_client, conn, case_id)
        return drawn

    def mirror(self, case_id):
        if self.nemo_client is None:
            return None
        with session() as conn:
            return channel.mirror(self.nemo_client, conn, case_id)

    def deliver(self, conversation_id=None):
        if self.shroud_client is None:
            return 0

        with session() as conn:
            queue = outbox.waiting(conn, conversation_id)

        sent = 0
        for queued in queue:
            with session() as conn:
                if self.hand_over(conn, queued):
                    sent += 1

        if sent:
            log.info("relay: sent %s queued message(s)", sent)

        return sent

    def hand_over(self, conn, queued):
        if queued.closed_at:
            outbox.stumbled(conn, queued.id, "the conversation is closed", True)
            log.info("relay: outbox %s is for a closed conversation", queued.id)
            return False

        try:
            posted = self.shroud_client.chat_postMessage(
                channel=queued.channel_id,
                thread_ts=queued.thread_ts,
                text=cards.to_member(queued.body),
                unfurl_links=False,
                unfurl_media=False,
                **self.wearing(queued),
            )
        except Exception as failure:
            outbox.stumbled(conn, queued.id, failure, queued.last_try)
            log.warning("relay: outbox %s did not go: %s", queued.id, failure)
            return False

        message_id, _ = intake.record(
            conn,
            {
                "channel": queued.channel_id,
                "ts": posted["ts"],
                "thread_ts": queued.thread_ts,
                "text": cards.to_member(queued.body),
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
            body, _ = store.body_of(conn, one.get("sha256"))
            if body is None:
                log.warning("relay: outbox %s lost the bytes of %s", queued.id, one.get("name"))
                continue
            try:
                self.shroud_client.files_upload_v2(
                    channel=queued.channel_id,
                    thread_ts=queued.thread_ts,
                    content=body,
                    filename=one.get("name") or "file",
                )
                carried += 1
            except Exception as failure:
                log.warning("relay: could not hand over %s: %s", one.get("name"), failure)
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

    def mark(self, at, emoji):
        if at is None or self.nemo_client is None:
            return
        channel_id, ts = at
        try:
            self.nemo_client.reactions_add(channel=channel_id, timestamp=ts, name=emoji)
        except Exception as failure:
            log.warning("relay: could not mark %s with %s: %s", ts, emoji, failure)

    def refuse(self, at, sent_by, said):
        self.mark(at, answer.STUCK)
        if at is None or self.nemo_client is None:
            return None
        channel_id, ts = at
        try:
            self.nemo_client.chat_postEphemeral(
                channel=channel_id, user=sent_by, thread_ts=ts, text=said
            )
        except Exception as failure:
            log.warning("relay: could not say why it did not send: %s", failure)
        return None

    def answered(self, thread_ts, text, sent_by, signed=True, files=(), at=None):
        if not (text or "").strip() and not files:
            return None

        with session() as conn:
            row = conn.execute(WHO_TO_REACH, (thread_ts,)).fetchone()
        if not row:
            log.info("relay: thread %s is not a report thread", thread_ts)
            return None
        conversation_id, _channel_id, _member_thread_ts, closed_at, report_id = row
        if closed_at:
            log.info("relay: conversation %s is closed, not queueing", conversation_id)
            return self.refuse(
                at, sent_by, f"conversation {conversation_id} is closed, so nothing was sent"
            )

        with session() as conn:
            kept = self.keep_outgoing(conn, files)
            queued_id = outbox.queue(
                conn,
                conversation_id,
                "reply",
                text,
                sent_by,
                mode="signed" if signed else "body",
                files=kept,
                asked_in=at[0] if at else None,
                asked_at=at[1] if at else None,
            )
            outbox.claim_echo(conn, queued_id)
            outbox.echoed(conn, queued_id, None, "user")
            if report_id:
                conn.execute(FIRST_ANSWER, (report_id,))
                audit.record(
                    conn,
                    "report",
                    report_id,
                    "answered",
                    sent_by,
                    after={"mode": "signed" if signed else "body", "source": "nemo"},
                )

        log.info(
            "relay: queued a %s answer for conversation %s as outbox %s",
            "signed" if signed else "unsigned", conversation_id, queued_id,
        )
        return queued_id

    def keep_outgoing(self, conn, files):
        kept = []
        if self.nemo_client is None:
            return kept

        for item in files or []:
            url = item.get("url_private_download") or item.get("url_private")
            name = item.get("name") or item.get("id") or "file"
            if not url:
                continue
            body = carry.fetch(url, self.nemo_client.token, store.cap())
            if body is None:
                log.warning("relay: %s could not be kept, it is not going out", name)
                continue
            kept.append({"name": name, "sha256": store.stash(conn, body, item.get("mimetype"))})
        return kept

    def echo_queued(self, case_id=None):
        if self.nemo_client is None:
            return 0

        with session() as conn:
            rows = outbox.to_echo(conn, case_id)

        done = 0
        for outbox_id, body, mode, requested_by, forwarded_ts in rows:
            with session() as conn:
                if not outbox.claim_echo(conn, outbox_id):
                    continue
                if requested_by and conn.execute(LINKED, (requested_by,)).fetchone():
                    outbox.echoed(conn, outbox_id, None, "user")
                    continue
                at = channel.echo(
                    self.nemo_client, forwarded_ts, requested_by, body, mode == "signed"
                )
                if at is None:
                    outbox.drop_echo(conn, outbox_id)
                    continue
                outbox.echoed(conn, outbox_id, at[1], "nemo")
                done += 1

        if done:
            log.info("relay: echoed %s queued message(s) into the firehouse", done)
        return done

    def tick_queued(self):
        if self.nemo_client is None:
            return 0

        with session() as conn:
            waiting = outbox.to_tick(conn)

        for outbox_id, channel_id, ts, failed_at, error in waiting:
            self.mark((channel_id, ts), answer.STUCK if failed_at else answer.SENT)
            if failed_at:
                self.tell_them_why(channel_id, ts, error)
            with session() as conn:
                outbox.ticked(conn, outbox_id)

        return len(waiting)

    def tell_them_why(self, channel_id, ts, error):
        try:
            self.nemo_client.chat_postMessage(
                channel=channel_id,
                thread_ts=ts,
                text=f":x: that did not reach them: {error or 'shroud could not send it'}",
                unfurl_links=False,
            )
        except Exception as failure:
            log.warning("relay: could not say why %s did not go: %s", ts, failure)
