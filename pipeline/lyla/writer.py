import datetime as dt
import logging

from psycopg.types.json import Jsonb

from bot.core import privileged
from bot.nemo.views.activity import message_url
from lyla import categories, digests, mapping, store

log = logging.getLogger("lyla")

BATCH = 100

CASES = "cases"
THREADS = "case_threads"
ACTIONS = "case_actions"
NOTES = "user_notes"

WAITING = """
SELECT id, entity, entity_id, case_id, op, before, after
FROM fd.lyla_outbox WHERE applied_at IS NULL
ORDER BY id LIMIT %s
"""

APPLIED = """
UPDATE fd.lyla_outbox
SET applied_at = now(), attempts = attempts + 1, error = NULL, conflict = %s
WHERE id = %s
"""

FAILED = "UPDATE fd.lyla_outbox SET attempts = attempts + 1, error = %s WHERE id = %s"

NEMO_CASE = """
SELECT id, resolved_at, resolution, duplicate_of, opened_at, card_channel_id,
       coalesce(card_thread_ts, card_ts)
FROM fd.cases WHERE id = %s
"""

REPORT_THREADS = """
SELECT card_channel_id, forwarded_ts, body FROM fd.case_reports
WHERE case_id = %s AND forwarded_ts IS NOT NULL AND card_channel_id IS NOT NULL
ORDER BY id
"""

OPENING = """
SELECT body FROM fd.case_chat WHERE case_id = %s AND mirrored_as = 'card' ORDER BY id LIMIT 1
"""

FAMILY_THREADS = """
WITH RECURSIVE family(id) AS (
    SELECT %(case_id)s::bigint
    UNION
    SELECT c.id FROM fd.cases c JOIN family f ON c.duplicate_of = f.id
)
SELECT channel_id, thread_ts FROM (
    SELECT 0 AS rank, c.id, c.card_channel_id AS channel_id, coalesce(c.card_thread_ts, c.card_ts) AS thread_ts
    FROM fd.cases c WHERE c.id IN (SELECT id FROM family)
    UNION ALL
    SELECT 1, r.case_id, r.card_channel_id, r.forwarded_ts
    FROM fd.case_reports r WHERE r.case_id IN (SELECT id FROM family)
) threads
WHERE channel_id IS NOT NULL AND thread_ts IS NOT NULL
ORDER BY id <> %(case_id)s, rank, id
"""

ANCESTORS = """
WITH RECURSIVE chain(id, parent) AS (
    SELECT id, duplicate_of FROM fd.cases WHERE id = %s
    UNION
    SELECT c.id, c.duplicate_of FROM fd.cases c JOIN chain ON c.id = chain.parent
)
SELECT id FROM chain
"""

NEMO_ASSIGNEES = "SELECT user_id, assigned_by, assigned_at FROM fd.case_assignees WHERE case_id = %s"

RESOLVER = """
SELECT actor_user_id FROM fd.audit
WHERE entity_type = 'case' AND entity_id = %s AND verb = 'resolved'
ORDER BY occurred_at DESC, id DESC LIMIT 1
"""

ACTOR = """
SELECT actor_user_id FROM fd.audit
WHERE entity_type = %s AND entity_id = %s AND actor_user_id IS NOT NULL
ORDER BY occurred_at DESC, id DESC LIMIT 1
"""

NEMO_ACTION = """
SELECT id, case_id, type_key, target_user_id, performed_by, performed_at, reason, solution,
       resolved_by, category_key, expires_at, details, reversed_at, external_ref, group_id
FROM fd.actions WHERE id = %s
"""

GROUP_IDS = "SELECT id FROM fd.actions WHERE group_id = %s ORDER BY id"

MEMBER_ACTIONS = "SELECT id, type_key, reversed_at, solution FROM fd.actions WHERE id = ANY(%s) ORDER BY id"

LINKED_ACTIONS = """
SELECT id, type_key, reversed_at, solution FROM fd.actions
WHERE external_ref LIKE %s OR id = ANY(%s)
ORDER BY id
"""

NEMO_NOTE = """
SELECT id, case_id, subject_user_id, body, author, created_at, edited_at, edited_by, deleted_at,
       deleted_by, external_ref
FROM fd.notes WHERE id = %s
"""

LYLA_CASE = """
SELECT case_number, status, resolved_by, resolved_at, merged_into FROM cases
WHERE case_number = %s FOR UPDATE
"""

INSERT_CASE = """
INSERT INTO cases (case_number, status, created_at, resolved_at, resolved_by, resolution_kind)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (case_number) DO NOTHING
"""

SET_STATUS = """
UPDATE cases SET status = %s, resolution_kind = %s, resolved_at = %s, resolved_by = %s,
                 merged_into = NULL
WHERE case_number = %s
"""

SET_RESOLVER = """
UPDATE cases SET resolved_by = %s, resolved_at = coalesce(%s, resolved_at)
WHERE case_number = %s AND status IN ('resolved', 'canceled')
"""

MERGE_STATUS = """
UPDATE cases SET status = 'merged', resolution_kind = 'merged', resolved_at = NULL, merged_into = %s
WHERE case_number = %s
"""

MOVE_THREADS = """
UPDATE case_threads SET case_number = %s, is_primary = false WHERE case_number = %s
RETURNING channel, thread_ts
"""

HAS_PRIMARY = "SELECT 1 FROM case_threads WHERE case_number = %s AND is_primary LIMIT 1"

PROMOTE = "UPDATE case_threads SET is_primary = true WHERE channel = %s AND thread_ts = %s"

MOVE_ASSIGNEES = """
INSERT INTO case_assignees (case_number, user_id, assigned_at, assignment_source)
SELECT %s, user_id, assigned_at, assignment_source FROM case_assignees WHERE case_number = %s
ON CONFLICT DO NOTHING
"""

DROP_ASSIGNEES = "DELETE FROM case_assignees WHERE case_number = %s"

RETURN_THREAD = """
UPDATE case_threads SET case_number = %s, is_primary = false
WHERE channel = %s AND thread_ts = %s AND case_number = ANY(%s)
RETURNING channel, thread_ts
"""

DROP_RETURNED_ASSIGNEES = """
DELETE FROM case_assignees WHERE case_number = %s AND user_id = ANY(%s) AND NOT (user_id = ANY(%s))
"""

THREAD_OWNER = "SELECT case_number FROM case_threads WHERE channel = %s AND thread_ts = %s"

ADD_THREAD = """
INSERT INTO case_threads (case_number, channel, thread_ts, added_at, is_primary, snippet)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (channel, thread_ts) DO NOTHING
"""

UCAT_PENDING = """
UPDATE case_actions SET ucat_sync_pending = true WHERE case_number = %s AND ucat_id IS NOT NULL
"""

LYLA_ACTION = """
SELECT id, case_number, action_type, target_user_id, performed_by, data, performed_at,
       category_code, category_extra, updated_at, ucat_id, ucat_sync_pending
FROM case_actions WHERE id = %s FOR UPDATE
"""

LYLA_ACTION_FOR = "SELECT id FROM case_actions WHERE data ->> 'nemoActionId' = %s LIMIT 1"

INSERT_ACTION = """
INSERT INTO case_actions
    (case_number, action_type, target_user_id, performed_by, data, performed_at, category_code)
VALUES (%s, %s, %s, %s, %s, %s, %s)
RETURNING id
"""

UPDATE_ACTION = """
UPDATE case_actions
SET action_type = %s, target_user_id = %s, performed_by = %s, data = %s, category_code = %s,
    updated_at = %s, ucat_sync_pending = (ucat_id IS NOT NULL OR ucat_sync_pending)
WHERE id = %s
"""

AUDIT = """
INSERT INTO audit_log
    (subject_type, subject_id, change_type, actor_id, before, after, case_number, target_user_id,
     created_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
"""

ADD_ASSIGNEE = """
INSERT INTO case_assignees (case_number, user_id, assigned_at, assignment_source)
VALUES (%s, %s, %s, %s)
ON CONFLICT DO NOTHING
"""

DROP_ASSIGNEE = "DELETE FROM case_assignees WHERE case_number = %s AND user_id = %s"

LYLA_NOTE = """
SELECT id, target_user_id, body, created_by, created_at, edited_by, edited_at
FROM user_notes WHERE id = %s FOR UPDATE
"""

SAME_NOTE = """
SELECT id FROM user_notes
WHERE target_user_id = %s AND body = %s AND created_by = %s AND created_at = %s
LIMIT 1
"""

INSERT_NOTE = """
INSERT INTO user_notes (target_user_id, body, created_by, created_at)
VALUES (%s, %s, %s, %s)
RETURNING id
"""

EDIT_NOTE = "UPDATE user_notes SET body = %s, edited_by = %s, edited_at = %s WHERE id = %s"

DELETE_NOTE = "DELETE FROM user_notes WHERE id = %s"

NOTE_FIELDS = ("id", "target_user_id", "body", "created_by", "created_at", "edited_by", "edited_at")
ACTION_FIELDS = ("id", "case_number", "action_type", "target_user_id", "performed_by", "data",
                 "performed_at", "category_code", "category_extra", "updated_at", "ucat_id",
                 "ucat_sync_pending")

SNIPPET_LENGTH = 100

_profiles = {}


def now_ms():
    return mapping.to_ms(dt.datetime.now(dt.UTC))


def snippet(text, length=SNIPPET_LENGTH):
    flat = " ".join(line.strip() for line in (text or "").split("\n")).strip()
    if len(flat) <= length:
        return flat or None
    cut = flat[:length]
    space = cut.rfind(" ")
    return (cut[:space] if space > 0 else cut).strip() + "..."


def profile(user_id):
    if user_id not in _profiles:
        member = privileged.profile(user_id) or {}
        details = member.get("profile") or {}
        _profiles[user_id] = {
            "email": details.get("email") or "",
            "displayName": details.get("display_name") or details.get("real_name")
            or member.get("real_name") or "",
        }
    return _profiles[user_id]


def actor(conn, entity_type, entity_id):
    row = conn.execute(ACTOR, (entity_type, entity_id)).fetchone()
    return row[0] if row else None


def resolver(conn, case_id):
    row = conn.execute(RESOLVER, (case_id,)).fetchone()
    return row[0] if row else None


def audit(lyla, subject_type, subject_id, change_type, actor_id, before, after, case_number=None,
          target_user_id=None):
    lyla.execute(AUDIT, (subject_type, subject_id, change_type, actor_id or mapping.LYLA_BOT_USER_ID,
                         Jsonb(before) if before else None, Jsonb(after) if after else None,
                         case_number, target_user_id, now_ms()))


def merge_into(lyla, source, target, keep_primary=False):
    if target is None:
        lyla.execute(MERGE_STATUS, (None, source))
        return
    moved = lyla.execute(MOVE_THREADS, (target, source)).fetchall()
    if keep_primary and moved and lyla.execute(HAS_PRIMARY, (target,)).fetchone() is None:
        lyla.execute(PROMOTE, moved[0])
    lyla.execute(MOVE_ASSIGNEES, (target, source))
    lyla.execute(DROP_ASSIGNEES, (source,))
    lyla.execute(MERGE_STATUS, (target, source))
    lyla.execute(UCAT_PENDING, (source,))


def unmerge_from(lyla, conn, case_id, merged_into):
    owners = [row[0] for row in conn.execute(ANCESTORS, (merged_into,)).fetchall()] or [merged_into]
    returned = []
    for channel_id, thread_ts in conn.execute(FAMILY_THREADS, {"case_id": case_id}).fetchall():
        returned += lyla.execute(RETURN_THREAD, (case_id, channel_id, thread_ts, owners)).fetchall()
    if returned and lyla.execute(HAS_PRIMARY, (case_id,)).fetchone() is None:
        lyla.execute(PROMOTE, returned[0])

    assignees = conn.execute(NEMO_ASSIGNEES, (case_id,)).fetchall()
    for user_id, assigned_by, assigned_at in assignees:
        source = "self" if assigned_by == user_id else "manual"
        lyla.execute(ADD_ASSIGNEE, (case_id, user_id, mapping.to_ms(assigned_at) or now_ms(), source))
    if assignees:
        kept = [row[0] for row in conn.execute(NEMO_ASSIGNEES, (merged_into,)).fetchall()]
        lyla.execute(DROP_RETURNED_ASSIGNEES, (merged_into, [row[0] for row in assignees], kept))
    return returned


def set_resolver(lyla, case_number, user_id, resolved_at=None):
    lyla.execute(SET_RESOLVER, (user_id, mapping.to_ms(resolved_at), case_number))


class Writer:
    def __init__(self, session, lyla):
        self.session = session
        self.lyla = lyla

    def drain(self, limit=BATCH):
        with self.session() as conn:
            rows = conn.execute(WAITING, (limit,)).fetchall()
        applied = 0
        for row in rows:
            outbox_id, case_id = row[0], row[3]
            try:
                with self.session() as conn:
                    conflict = self.conflict(conn, case_id) if case_id else None
                    conflict = self.apply(conn, *row[1:]) or conflict
                    if case_id and not conflict:
                        self.settle(conn, case_id)
                    self.lyla.commit()
                    conn.execute(APPLIED, (conflict, outbox_id))
            except Exception as failure:
                self.lyla.rollback()
                with self.session() as conn:
                    conn.execute(FAILED, (str(failure)[:500], outbox_id))
                log.warning("lyla: outbox %s could not be written to LYLA: %s", outbox_id, failure)
                raise
            applied += 1
        return applied, len(rows) == limit

    def apply(self, conn, entity, entity_id, case_id, op, before, after):
        if entity == "cases":
            return self.apply_case(conn, entity_id, op)
        if entity == "case_reports":
            return self.apply_report(conn, after)
        if entity == "actions":
            return self.apply_action(conn, entity_id, op)
        if entity == "case_assignees":
            return self.apply_assignee(op, before, after)
        if entity == "notes":
            return self.apply_note(conn, entity_id, op, before)
        return None

    def conflict(self, conn, case_number):
        mapped = store.mapped(conn, CASES, case_number)
        if not mapped or not mapped[2]:
            return None
        current = digests.one_case(self.lyla, case_number)
        if current is not None and current != mapped[2]:
            return f"LYLA case {case_number} changed since the last read"
        return None

    def settle(self, conn, case_number):
        current = digests.one_case(self.lyla, case_number)
        if current is not None:
            store.put(conn, CASES, case_number, "cases", case_number, current)

    def apply_case(self, conn, case_id, op):
        if op == "delete":
            return None
        case = conn.execute(NEMO_CASE, (case_id,)).fetchone()
        if case is None:
            return None
        _id, resolved_at, resolution, duplicate_of, opened_at, card_channel, card_thread = case
        status = mapping.lyla_status(resolved_at, resolution)
        closed_by = resolver(conn, case_id) if status in (mapping.RESOLVED, mapping.CANCELED) else None
        conflict = None
        current = self.lyla.execute(LYLA_CASE, (case_id,)).fetchone()

        if current is None:
            closed = status in (mapping.RESOLVED, mapping.CANCELED)
            self.lyla.execute(INSERT_CASE, (
                case_id, status if status != mapping.MERGED else mapping.OPEN,
                mapping.to_ms(opened_at), mapping.to_ms(resolved_at) if closed else None,
                closed_by, status if closed else None,
            ))
            if status == mapping.MERGED:
                merge_into(self.lyla, case_id, duplicate_of)
        else:
            _number, lyla_status, lyla_resolver, _at, merged_into = current
            if status == mapping.MERGED:
                if lyla_status != mapping.MERGED or merged_into != duplicate_of:
                    merge_into(self.lyla, case_id, duplicate_of)
            elif status != lyla_status:
                if lyla_status == mapping.MERGED and merged_into:
                    unmerge_from(self.lyla, conn, case_id, merged_into)
                closed = status != mapping.OPEN
                self.lyla.execute(SET_STATUS, (
                    status, status if closed else None,
                    mapping.to_ms(resolved_at) if closed else None, closed_by, case_id,
                ))
                self.lyla.execute(UCAT_PENDING, (case_id,))
            elif closed_by and closed_by != lyla_resolver:
                set_resolver(self.lyla, case_id, closed_by, resolved_at)

        if status == mapping.MERGED:
            return conflict
        threads = []
        if card_channel and card_thread:
            body = conn.execute(OPENING, (case_id,)).fetchone()
            threads.append((card_channel, card_thread, body[0] if body else None))
        threads += conn.execute(REPORT_THREADS, (case_id,)).fetchall()
        for channel_id, thread_ts, body in threads:
            conflict = self.claim_thread(conn, case_id, channel_id, thread_ts, opened_at, body) or conflict
        return conflict

    def apply_report(self, conn, after):
        case_id = (after or {}).get("case_id")
        channel_id, thread_ts = (after or {}).get("card_channel_id"), (after or {}).get("forwarded_ts")
        if not case_id or not channel_id or not thread_ts:
            return None
        case = conn.execute(NEMO_CASE, (case_id,)).fetchone()
        if case is None:
            return None
        if self.lyla.execute(LYLA_CASE, (case_id,)).fetchone() is None:
            self.apply_case(conn, case_id, "update")
        return self.claim_thread(conn, case_id, channel_id, thread_ts, case[4], (after or {}).get("body"))

    def claim_thread(self, conn, case_id, channel_id, thread_ts, at, body=None):
        owner = self.lyla.execute(THREAD_OWNER, (channel_id, thread_ts)).fetchone()
        if owner and owner[0] != case_id:
            return f"thread {channel_id} {thread_ts} is on LYLA case {owner[0]}"
        if owner is None:
            primary = self.lyla.execute(HAS_PRIMARY, (case_id,)).fetchone() is None
            self.lyla.execute(ADD_THREAD, (case_id, channel_id, thread_ts, mapping.to_ms(at) or now_ms(),
                                           primary, snippet(body)))
        key = mapping.thread_key(channel_id, thread_ts)
        if store.mapped(conn, THREADS, key) is None:
            store.put(conn, THREADS, key, "cases", case_id)
            store.touch_case(conn, case_id)
        return None

    def group_ids(self, conn, action):
        if action[14] is None:
            return [action[0]]
        return [row[0] for row in conn.execute(GROUP_IDS, (action[14],)).fetchall()] or [action[0]]

    def lyla_action_id(self, conn, action):
        external_ref = action[13] or ""
        if external_ref.startswith("lyla:action:"):
            return int(external_ref.split(":")[2])
        member_ids = self.group_ids(conn, action)
        for member_id in member_ids:
            keys = store.keys_for(conn, ACTIONS, "actions", member_id)
            if keys:
                return int(keys[0])
        for member_id in member_ids:
            row = self.lyla.execute(LYLA_ACTION_FOR, (str(member_id),)).fetchone()
            if row:
                return row[0]
        return None

    def apply_action(self, conn, action_id, op):
        if op == "delete":
            return None
        action = conn.execute(NEMO_ACTION, (action_id,)).fetchone()
        if action is None:
            return None
        lyla_id = self.lyla_action_id(conn, action)
        if lyla_id is None:
            return self.insert_action(conn, action)
        return self.update_action(conn, action, lyla_id)

    def action_data(self, conn, action, data=None):
        (action_id, case_id, type_key, target, _performed_by, _performed_at, reason, _solution,
         _resolved_by, _category_key, expires_at, details, _reversed_at, _external_ref, _group_id) = action
        data = dict(data or {})
        data["whatTheyDid"] = reason or ""
        if type_key in mapping.EXPIRING_TYPES:
            data["banUntil"] = mapping.ban_until(expires_at)
        if (details or {}).get("channel_id"):
            data["channelBanChannel"] = details["channel_id"]
        data.setdefault("nemoActionId", str(action_id))
        return data

    def permalink(self, conn, case_id):
        case = conn.execute(NEMO_CASE, (case_id,)).fetchone()
        reports = conn.execute(REPORT_THREADS, (case_id,)).fetchall()
        if reports:
            return message_url(reports[0][0], reports[0][1])
        if case and case[5] and case[6]:
            return message_url(case[5], case[6])
        return None

    def insert_action(self, conn, action):
        (action_id, case_id, type_key, target, performed_by, performed_at, _reason, solution,
         resolved_by, category_key, _expires_at, details, reversed_at, _external_ref, _group_id) = action
        if not target:
            return "no target, kept in Nemo"
        if self.lyla.execute(LYLA_CASE, (case_id,)).fetchone() is None:
            raise RuntimeError(f"LYLA has no case {case_id} yet")
        names = categories.load(conn, self.lyla)
        member = profile(target)
        data = self.action_data(conn, action, {
            "email": member["email"], "displayName": member["displayName"],
            "permalink": self.permalink(conn, case_id),
        })
        members = conn.execute(MEMBER_ACTIONS, (self.group_ids(conn, action),)).fetchall()
        types = [(row[1], row[2] is not None) for row in members] or [(type_key, reversed_at is not None)]
        solution = next((row[3] for row in members if row[3]), solution)
        lyla_id = self.lyla.execute(INSERT_ACTION, (
            case_id, mapping.compose_action_type(types, solution),
            target, list(resolved_by or []) or [performed_by], Jsonb(data),
            mapping.to_ms(performed_at), names.code_for(category_key),
        )).fetchone()[0]
        store.put(conn, ACTIONS, lyla_id, "actions", action_id)
        return None

    def update_action(self, conn, action, lyla_id):
        (action_id, case_id, type_key, target, performed_by, _performed_at, _reason, _solution,
         resolved_by, category_key, _expires_at, _details, _reversed_at, _external_ref, _group_id) = action
        current = self.lyla.execute(LYLA_ACTION, (lyla_id,)).fetchone()
        if current is None:
            return None
        before = dict(zip(ACTION_FIELDS, current))
        linked = conn.execute(LINKED_ACTIONS, (f"lyla:action:{lyla_id}:%", self.group_ids(conn, action))).fetchall()
        types = [(row[1], row[2] is not None) for row in linked]
        solution = next((row[3] for row in linked if row[3]), None)
        parsed = mapping.parse_action_type(before["action_type"], bool(before["data"].get("banUntil")))
        action_type = (before["action_type"] if parsed == (types, solution)
                       else mapping.compose_action_type(types, solution))
        names = categories.load(conn, self.lyla)
        code = names.code_for(category_key)
        after = dict(before)
        after.update({
            "action_type": action_type,
            "target_user_id": target or before["target_user_id"],
            "performed_by": list(resolved_by or []) or [performed_by],
            "data": self.action_data(conn, action, before["data"]),
            "category_code": code if code is not None else before["category_code"],
        })
        if all(after[key] == before[key] for key in ACTION_FIELDS):
            return None
        after["updated_at"] = now_ms()
        self.lyla.execute(UPDATE_ACTION, (
            after["action_type"], after["target_user_id"], after["performed_by"],
            Jsonb(after["data"]), after["category_code"], after["updated_at"], lyla_id,
        ))
        audit(self.lyla, "case_action", lyla_id, "edit", actor(conn, "action", action_id),
              before, after, before["case_number"], before["target_user_id"])
        return None

    def apply_assignee(self, op, before, after):
        row = after if op == "insert" else before
        case_id, user_id = row.get("case_id"), row.get("user_id")
        if op == "insert":
            if self.lyla.execute(LYLA_CASE, (case_id,)).fetchone() is None:
                raise RuntimeError(f"LYLA has no case {case_id} yet")
            source = "self" if row.get("assigned_by") == user_id else "manual"
            assigned_at = dt.datetime.fromisoformat(row["assigned_at"]) if row.get("assigned_at") else None
            self.lyla.execute(ADD_ASSIGNEE, (case_id, user_id, mapping.to_ms(assigned_at) or now_ms(),
                                             source))
        elif op == "delete":
            self.lyla.execute(DROP_ASSIGNEE, (case_id, user_id))
        return None

    def lyla_note_id(self, conn, note):
        external_ref = note[10] or ""
        if external_ref.startswith("lyla:note:"):
            return int(external_ref.split(":")[2])
        keys = store.keys_for(conn, NOTES, "notes", note[0])
        return int(keys[0]) if keys else None

    def apply_note(self, conn, note_id, op, before):
        note = conn.execute(NEMO_NOTE, (note_id,)).fetchone()
        if note is None:
            return None
        (_id, case_id, subject, body, author, created_at, edited_at, edited_by, deleted_at,
         deleted_by, _external_ref) = note
        if case_id is not None or not subject:
            return None
        lyla_id = self.lyla_note_id(conn, note)
        if lyla_id is None:
            if deleted_at:
                return None
            created = mapping.to_ms(created_at)
            same = self.lyla.execute(SAME_NOTE, (subject, body, author, created)).fetchone()
            lyla_id = same[0] if same else self.lyla.execute(
                INSERT_NOTE, (subject, body, author, created)).fetchone()[0]
            store.put(conn, NOTES, lyla_id, "notes", note_id)
            return None
        current = self.lyla.execute(LYLA_NOTE, (lyla_id,)).fetchone()
        if current is None:
            return None
        previous = dict(zip(NOTE_FIELDS, current))
        if deleted_at:
            self.lyla.execute(DELETE_NOTE, (lyla_id,))
            audit(self.lyla, "user_note", lyla_id, "delete", deleted_by, previous, None,
                  target_user_id=subject)
            return None
        if previous["body"] == body:
            return None
        edited = mapping.to_ms(edited_at) or now_ms()
        self.lyla.execute(EDIT_NOTE, (body, edited_by or author, edited, lyla_id))
        audit(self.lyla, "user_note", lyla_id, "edit", edited_by or author, previous,
              {**previous, "body": body, "edited_by": edited_by or author, "edited_at": edited},
              target_user_id=subject)
        return None
