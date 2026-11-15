import argparse
import collections
import datetime as dt
import logging
import os
import sys
import time

import psycopg
from dotenv import load_dotenv
from slack_sdk import WebClient

from bot.core import intake, parse, session, shutdown
from bot.core.identity import ensure_member
from bot.nemo.channel import card_mark, card_state
from bot.relay import consent, dm
from jobs import shroud_identity
from lib.paths import ENV_FILE
from lib.slack_client import RETRY_HANDLERS
from lyla import store

log = logging.getLogger("shroud_import")

SOURCE = "shroud"
URL = "SHROUD_DATABASE_URL"
NAMED = "with_username"
IMPORTED = "imported"
PACE_SECONDS = 1.2

REPORTS = """
SELECT id, dm_ts, dm_channel, forwarded_ts, selection_ts, selection, content, reply_time,
       is_auto_forward, created_at, updated_at
FROM reports
WHERE updated_at > %s
ORDER BY id
"""

CASE_FOR_THREAD = """
SELECT id, card_channel_id, resolved_at, resolution FROM fd.cases WHERE card_thread_ts = %(ts)s
UNION ALL
SELECT c.id, t.channel_id, c.resolved_at, c.resolution
FROM fd.case_threads t JOIN fd.cases c ON c.id = t.case_id
WHERE t.thread_ts = %(ts)s AND t.removed_at IS NULL
LIMIT 1
"""

REPORT_BY_REF = "SELECT id, case_id FROM fd.case_reports WHERE external_ref = %s"

CONVERSATION = "SELECT id, report_id FROM fd.intake_conversations WHERE channel_id = %s AND thread_ts = %s"

INSERT_CONVERSATION = """
INSERT INTO fd.intake_conversations
    (channel_id, thread_ts, member_user_id, opened_at, last_message_at, source_app, consent_choice,
     closed_at, closed_by)
VALUES (%s, %s, %s, %s, %s, 'shroud', %s, %s, %s)
ON CONFLICT DO NOTHING
"""

HAND_OFF = """
UPDATE fd.intake_conversations SET report_id = %s, handed_off_at = %s
WHERE id = %s AND report_id IS NULL
"""

INSERT_REPORT = """
INSERT INTO fd.case_reports
    (case_id, reporter_user_id, is_anonymous, body, received_at, dm_channel_id, dm_ts,
     forwarded_ts, first_replied_at, closed_at, closed_by, source_app, external_ref, card_digest,
     card_channel_id, entry_point)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'shroud', %s, %s, %s, 'dm')
ON CONFLICT (external_ref) DO NOTHING
RETURNING id
"""

INSERT_MESSAGE = """
INSERT INTO fd.intake_messages
    (conversation_id, channel_id, ts, thread_ts, direction, author_user_id, subtype, body,
     posted_at, mirrored_ts, mirrored_at, shown_body, unfurled_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (channel_id, ts) DO UPDATE
SET mirrored_ts = coalesce(fd.intake_messages.mirrored_ts, EXCLUDED.mirrored_ts),
    mirrored_at = coalesce(fd.intake_messages.mirrored_at, EXCLUDED.mirrored_at),
    shown_body = coalesce(fd.intake_messages.shown_body, EXCLUDED.shown_body),
    unfurled_at = coalesce(fd.intake_messages.unfurled_at, EXCLUDED.unfurled_at),
    last_seen_at = now()
RETURNING id, (xmax = 0)
"""

INSERT_REVISION = """
INSERT INTO fd.intake_revisions (message_id, seq, body, digest)
VALUES (%s, 0, %s, %s)
ON CONFLICT (message_id, seq) DO NOTHING
"""

RESOLVER = """
SELECT actor_user_id FROM fd.audit
WHERE entity_type = 'case' AND entity_id = %s AND verb = 'resolved'
ORDER BY occurred_at DESC, id DESC LIMIT 1
"""

UNSENT = """
SELECT c.id, c.channel_id, m.ts, c.consent_choice
FROM fd.intake_conversations c
JOIN fd.intake_messages m ON m.conversation_id = c.id
WHERE c.source_app = 'shroud' AND c.handed_off_at IS NULL AND c.closed_at IS NULL
  AND m.direction = 'outbound' AND m.subtype = %s AND m.deleted_at IS NULL
ORDER BY c.id
"""

MARK_FILES_POSTED = """
UPDATE fd.intake_message_files mf
SET mirrored_at = now(), mirrored_file_id = f.slack_file_id
FROM fd.intake_files f
WHERE f.id = mf.file_id AND mf.message_id = %s AND mf.mirrored_at IS NULL
"""

MARK_FILES_NOTIFIED = """
UPDATE fd.intake_files f
SET reporter_notified_at = now()
FROM fd.intake_message_files mf
WHERE mf.file_id = f.id AND mf.message_id = %s AND f.reporter_notified_at IS NULL
"""


def connect():
    return psycopg.connect(os.environ[URL], options="-c default_transaction_read_only=on")


def slack_time(ts):
    return parse.posted_at(ts) if ts else None


def dm_attachments(message, anonymous):
    files = message.get("files") or []
    if anonymous:
        files = [{key: value for key, value in entry.items() if key != "user"} for entry in files]
    return {"attachments": message.get("attachments") or [], "files": files}


def attach_dm_message(conn, conversation_id, message_id, message, anonymous):
    parts = dm_attachments(message, anonymous)
    intake.attach(conn, message_id, parts)
    conn.execute(MARK_FILES_POSTED, (message_id,))
    conn.execute(MARK_FILES_NOTIFIED, (message_id,))
    if anonymous and parts["files"]:
        intake.rename_anonymous_files(conn, conversation_id)
    return parts


class Import:
    def __init__(self, identity):
        self.identity = identity
        self.summary = collections.Counter()

    def run(self, rows):
        for row in rows:
            try:
                with session() as conn:
                    store.as_lyla(conn)
                    self.one(conn, *row)
            except Exception:
                log.exception("shroud import: report %s failed", row[0])
                self.summary["failed"] += 1
        return self.summary

    def one(self, conn, report_id, dm_ts, dm_channel, forwarded_ts, selection_ts, selection, content,
            reply_time, auto_forward, created_at, _updated_at):
        if forwarded_ts:
            self.forwarded(conn, report_id, dm_ts, dm_channel, forwarded_ts, selection_ts, content,
                           reply_time, auto_forward, created_at)
        else:
            self.unsent(conn, dm_ts, dm_channel, selection_ts, selection, content, created_at)

    def conversation(self, conn, dm_channel, dm_ts, member, choice, opened_at, closed_by=None):
        ensure_member(conn, member)
        conn.execute(INSERT_CONVERSATION, (
            dm_channel, dm_ts, member, opened_at, opened_at, choice,
            opened_at if closed_by else None, closed_by,
        ))
        return conn.execute(CONVERSATION, (dm_channel, dm_ts)).fetchone()

    def first_message(self, conn, conversation_id, dm_channel, dm_ts, author, content, mirrored_ts,
                      created_at):
        row = conn.execute(INSERT_MESSAGE, (
            conversation_id, dm_channel, dm_ts, None, "inbound", author,
            None if author else IMPORTED, content, slack_time(dm_ts), mirrored_ts,
            created_at if mirrored_ts else None, content if mirrored_ts else None,
            created_at if mirrored_ts else None,
        )).fetchone()
        if row and row[1]:
            conn.execute(INSERT_REVISION, (row[0], content, parse.digest(content, None, None)))
        return row[0] if row else None

    def attach(self, conn, conversation_id, message_id, dm_channel, dm_ts, anonymous):
        message = self.identity.dms.one(dm_channel, dm_ts) if message_id and dm_channel and dm_ts else None
        if message:
            attach_dm_message(conn, conversation_id, message_id, message, anonymous)

    def forwarded(self, conn, report_id, dm_ts, dm_channel, forwarded_ts, selection_ts, content,
                  reply_time, auto_forward, created_at):
        ref = f"shroud:report:{report_id}"
        case = conn.execute(CASE_FOR_THREAD, {"ts": forwarded_ts}).fetchone()
        if case is None:
            log.info("shroud import: report %s has no case on its thread", report_id)
            self.summary["no_case"] += 1
            return
        case_id, channel_id, resolved_at, resolution = case
        if conn.execute(REPORT_BY_REF, (ref,)).fetchone():
            self.summary["already"] += 1
            return

        kind = shroud_identity.kind_of(auto_forward, selection_ts)
        forward = self.identity.forwards.one(channel_id, forwarded_ts)
        choice, reporter = self.identity.decide(kind, forward, dm_channel, dm_ts)
        if choice == shroud_identity.UNKNOWN:
            log.info("shroud import: report %s shows no reporter, it stays anonymous", report_id)
        named = choice == shroud_identity.NAMED
        closed_by = intake.TRUSTED_SENDER if auto_forward else None
        conversation_id, attached = self.conversation(
            conn, dm_channel, dm_ts, reporter, consent.NAMED if named else consent.ANONYMOUS,
            created_at, closed_by)
        if attached:
            self.summary["conversation_taken"] += 1
            return

        resolver = None
        if resolved_at:
            row = conn.execute(RESOLVER, (case_id,)).fetchone()
            resolver = (row[0] if row else None) or SOURCE
        replied = (parse.posted_at(forwarded_ts) + dt.timedelta(seconds=reply_time)) if reply_time else None
        digest = card_state(card_mark({"resolved_at": resolved_at, "resolution": resolution}))
        ensure_member(conn, reporter)
        row = conn.execute(INSERT_REPORT, (
            case_id, reporter if named else None, not named, content, created_at,
            dm_channel if named else None, dm_ts if named else None, forwarded_ts, replied,
            resolved_at, resolver, ref, digest if resolved_at else card_state(None), channel_id,
        )).fetchone()
        if row is None:
            self.summary["already"] += 1
            return
        conn.execute(HAND_OFF, (row[0], created_at, conversation_id))
        message_id = self.first_message(conn, conversation_id, dm_channel, dm_ts, reporter, content,
                                        forwarded_ts, created_at)
        self.attach(conn, conversation_id, message_id, dm_channel, dm_ts, not named)
        self.summary["reports"] += 1

    def unsent(self, conn, dm_ts, dm_channel, selection_ts, selection, content, created_at):
        if conn.execute(CONVERSATION, (dm_channel, dm_ts)).fetchone():
            self.summary["already"] += 1
            return
        member = self.identity.dm_author(dm_channel, dm_ts)
        if not member:
            self.summary["unsent_gone"] += 1
            return
        choice = consent.NAMED if selection == NAMED else consent.ANONYMOUS
        conversation_id, attached = self.conversation(conn, dm_channel, dm_ts, member, choice, created_at)
        if attached:
            return
        message_id = self.first_message(conn, conversation_id, dm_channel, dm_ts, member, content, None,
                                        created_at)
        self.attach(conn, conversation_id, message_id, dm_channel, dm_ts, choice != consent.NAMED)
        if selection_ts:
            conn.execute(INSERT_MESSAGE, (
                conversation_id, dm_channel, selection_ts, dm_ts, "outbound", None, consent.SUBTYPE,
                consent.FALLBACK, slack_time(selection_ts), None, None, None, None,
            ))
        self.summary["unsent"] += 1


def takeover(client):
    redrawn = 0
    with session() as conn:
        prompts = conn.execute(UNSENT, (consent.SUBTYPE,)).fetchall()
    for conversation_id, channel_id, prompt_ts, choice in prompts:
        with session() as conn:
            blocks = dm.preview(conn, conversation_id, choice)
        try:
            client.chat_update(channel=channel_id, ts=prompt_ts, text=consent.FALLBACK, blocks=blocks)
            redrawn += 1
        except Exception as failure:
            log.warning("shroud takeover: prompt %s in %s stays as it was: %s", prompt_ts, channel_id,
                        failure)
        time.sleep(PACE_SECONDS)
    return redrawn, len(prompts)


def main(argv=None):
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(),
                        format="%(asctime)s %(name)s %(message)s")
    load_dotenv(ENV_FILE)
    parser = argparse.ArgumentParser(prog="nemo shroud-import")
    parser.add_argument("--since", type=dt.datetime.fromisoformat)
    parser.add_argument("--takeover", action="store_true")
    args = parser.parse_args(argv)
    if not os.environ.get("RELAY_BOT_TOKEN"):
        print("shroud import: RELAY_BOT_TOKEN is not set", file=sys.stderr)
        return 78
    client = WebClient(token=os.environ["RELAY_BOT_TOKEN"], retry_handlers=RETRY_HANDLERS)
    nemo = (WebClient(token=os.environ["NEMO_BOT_TOKEN"], retry_handlers=RETRY_HANDLERS)
            if os.environ.get("NEMO_BOT_TOKEN") else None)
    try:
        if args.takeover:
            redrawn, prompts = takeover(client)
            print(f"shroud takeover: {redrawn} of {prompts} prompt(s) redrawn")
            return 0
        if not os.environ.get(URL):
            print(f"shroud import: {URL} is not set", file=sys.stderr)
            return 78
        since = args.since or dt.datetime(1970, 1, 1, tzinfo=dt.UTC)
        with connect() as shroud:
            rows = shroud.execute(REPORTS, (since,)).fetchall()
        identity = shroud_identity.Identity(shroud_identity.Messages([client, nemo]),
                                            shroud_identity.Messages([client]))
        summary = Import(identity).run(rows)
        for key, count in sorted(summary.items()):
            print(f"shroud import: {key} {count}")
        print(f"shroud import: {len(rows)} Shroud row(s) read")
        return 1 if summary.get("failed") else 0
    finally:
        shutdown()


if __name__ == "__main__":
    sys.exit(main())
