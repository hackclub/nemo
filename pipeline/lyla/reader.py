import collections
import datetime as dt
import logging

from psycopg.types.json import Jsonb

from bot.core import merges
from lyla import categories, digests, mapping, numbers, store, writer
from lyla.mapping import LYLA_BOT_USER_ID

log = logging.getLogger("lyla")

CASES = "cases"
THREADS = "case_threads"
ACTIONS = "case_actions"
NOTES = "user_notes"

CHUNK = 500

LYLA_CASES = """
SELECT case_number, status, created_at, resolved_at, resolved_by, resolution_kind, merged_into
FROM cases WHERE case_number = ANY(%s)
"""

LYLA_THREADS = """
SELECT case_number, channel, thread_ts, is_primary, added_at
FROM case_threads WHERE case_number = ANY(%s)
ORDER BY is_primary DESC, added_at
"""

LYLA_ASSIGNEES = """
SELECT case_number, user_id, assigned_at, assignment_source
FROM case_assignees WHERE case_number = ANY(%s)
"""

ACTION_COLUMNS = f"""
x.id, x.case_number, x.action_type, x.target_user_id, x.performed_by, x.data, x.performed_at,
x.category_code, x.category_extra, x.updated_at, {digests.ACTION}
"""

LYLA_ACTIONS = f"SELECT {ACTION_COLUMNS} FROM case_actions x WHERE x.case_number = ANY(%s) ORDER BY x.id"

GROUP_IMPORTED = """
UPDATE fd.actions a SET group_id = grouped.first_id
FROM (SELECT min(id) AS first_id, count(*) AS types FROM fd.actions WHERE external_ref LIKE %(prefix)s) grouped
WHERE a.external_ref LIKE %(prefix)s AND grouped.types > 1 AND a.group_id IS DISTINCT FROM grouped.first_id
"""

LYLA_ACTIONS_BY_ID = f"SELECT {ACTION_COLUMNS} FROM case_actions x WHERE x.id = ANY(%s) ORDER BY x.id"

LYLA_ACTION_IDS = "SELECT id FROM case_actions"

LYLA_NOTES = """
SELECT id, target_user_id, body, created_by, created_at, edited_by, edited_at,
       md5(concat_ws('|', target_user_id, body, created_by, created_at, edited_by, edited_at))
FROM user_notes WHERE id = ANY(%s)
"""

WAITING_CASES = """
SELECT DISTINCT case_id FROM fd.lyla_outbox WHERE applied_at IS NULL AND case_id IS NOT NULL
"""

WAITING_NOTES = """
SELECT DISTINCT entity_id FROM fd.lyla_outbox WHERE applied_at IS NULL AND entity = 'notes'
"""

EXISTING_CASES = "SELECT id FROM fd.cases WHERE id = ANY(%s)"

THREAD_OWNER = """
SELECT id FROM fd.cases
WHERE card_channel_id = %(channel)s AND (card_ts = %(ts)s OR card_thread_ts = %(ts)s)
UNION ALL
SELECT case_id FROM fd.case_reports WHERE card_channel_id = %(channel)s AND forwarded_ts = %(ts)s
LIMIT 1
"""

INSERT_CASE = """
INSERT INTO fd.cases
    (id, opened_by, opened_at, created_at, source_app, external_ref, card_channel_id, card_thread_ts)
OVERRIDING SYSTEM VALUE
VALUES (%s, %s, %s, %s, 'lyla', %s, %s, %s)
ON CONFLICT (id) DO NOTHING
"""

INSERT_THREAD_CASE = """
INSERT INTO fd.cases
    (opened_by, opened_at, created_at, source_app, external_ref, card_channel_id, card_thread_ts)
VALUES (%s, %s, %s, 'lyla', %s, %s, %s)
RETURNING id
"""

NEMO_CASE = """
SELECT id, resolved_at, resolution, duplicate_of, opened_at
FROM fd.cases WHERE id = %s
FOR UPDATE
"""

CARD_THREADS = """
SELECT card_channel_id, coalesce(card_thread_ts, card_ts) FROM fd.cases
WHERE id = %(case_id)s AND card_channel_id IS NOT NULL
UNION
SELECT card_channel_id, forwarded_ts FROM fd.case_reports
WHERE case_id = %(case_id)s AND forwarded_ts IS NOT NULL
"""

LIVE_ACTION_COUNT = "SELECT count(*) FROM fd.actions WHERE case_id = %s AND reversed_at IS NULL"

RESOLVER = """
SELECT actor_user_id FROM fd.audit
WHERE entity_type = 'case' AND entity_id = %s AND verb = 'resolved'
ORDER BY occurred_at DESC, id DESC LIMIT 1
"""

RESOLVE = """
UPDATE fd.cases
SET resolved_at = %s, resolution = %s, duplicate_of = %s, updated_at = now()
WHERE id = %s
"""

REOPEN = """
UPDATE fd.cases
SET resolved_at = NULL, resolution = NULL, duplicate_of = NULL, updated_at = now()
WHERE id = %s
"""

CLOSE_REPORTS = """
UPDATE fd.case_reports SET closed_at = %s, closed_by = %s
WHERE case_id = %s AND closed_at IS NULL
"""

REOPEN_REPORTS = """
UPDATE fd.case_reports SET closed_at = NULL, closed_by = NULL
WHERE case_id = %s AND closed_at IS NOT NULL
"""

ADD_THREAD = """
INSERT INTO fd.case_threads (case_id, channel_id, thread_ts, is_primary, added_by, added_at, kind)
VALUES (%s, %s, %s, false, %s, %s, 'evidence')
ON CONFLICT (case_id, channel_id, thread_ts) DO NOTHING
"""

NEMO_ASSIGNEES = "SELECT user_id FROM fd.case_assignees WHERE case_id = %s"

ADD_ASSIGNEE = """
INSERT INTO fd.case_assignees (case_id, user_id, assigned_at, assigned_by)
VALUES (%s, %s, %s, %s)
ON CONFLICT DO NOTHING
RETURNING user_id
"""

REMOVE_ASSIGNEE = """
DELETE FROM fd.case_assignees WHERE case_id = %s AND user_id = %s RETURNING assigned_by
"""

LINKED_ACTIONS = """
SELECT id, type_key, target_user_id, reason, solution, resolved_by, category_key, expires_at,
       details, reversed_at, performed_by, case_id
FROM fd.actions
WHERE external_ref LIKE %s OR id = %s
ORDER BY id
"""

INSERT_ACTION = """
INSERT INTO fd.actions
    (case_id, type_key, target_user_id, decided_by, performed_by, performed_at, source_app,
     expires_at, reversed_at, reversed_by, reversal_reason, details, external_ref, reason,
     category_key, solution, resolved_by)
VALUES (%s, %s, %s, %s, %s, %s, 'lyla', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (external_ref) DO NOTHING
RETURNING id
"""

UPDATE_ACTION = """
UPDATE fd.actions
SET target_user_id = %s, reason = %s, solution = %s, resolved_by = %s, category_key = %s,
    expires_at = %s, details = %s
WHERE id = %s
"""

REVERSE_ACTION = """
UPDATE fd.actions SET reversed_at = coalesce(%s, now()), reversed_by = %s, reversal_reason = %s
WHERE id = %s AND reversed_at IS NULL
RETURNING id
"""

ADD_SUBJECT = """
INSERT INTO fd.case_participants (case_id, user_id, role)
VALUES (%s, %s, 'subject')
ON CONFLICT DO NOTHING
"""

INSERT_CASE_NOTE = """
INSERT INTO fd.notes (case_id, body, author, created_at, updated_at, external_ref)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (external_ref) DO NOTHING
RETURNING id
"""

INSERT_MEMBER_NOTE = """
INSERT INTO fd.notes
    (subject_user_id, body, author, created_at, updated_at, edited_at, edited_by, external_ref)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (external_ref) DO NOTHING
RETURNING id
"""

NOTE = "SELECT id, body, deleted_at FROM fd.notes WHERE id = %s"

EDIT_NOTE = """
UPDATE fd.notes SET body = %s, edited_at = coalesce(%s, now()), edited_by = %s, updated_at = now()
WHERE id = %s
"""

DELETE_NOTE = """
UPDATE fd.notes SET deleted_at = now(), deleted_by = %s, updated_at = now()
WHERE id = %s AND deleted_at IS NULL
"""

DELETED_IN_LYLA = "Deleted in LYLA"
REMOVED_IN_LYLA = "Removed in LYLA"
REVERSED_IN_LYLA = "Reversed in LYLA"

Rows = collections.namedtuple("Rows", "cases threads assignees actions")


def chunks(values, size=CHUNK):
    for start in range(0, len(values), size):
        yield values[start:start + size]


def grouped(rows, key=0):
    groups = collections.defaultdict(list)
    for row in rows:
        groups[row[key]].append(row)
    return groups


def action_row(row):
    (action_id, case_number, action_type, target, performed_by, data, performed_at,
     category_code, category_extra, updated_at, digest) = row
    return {
        "id": action_id, "case_number": case_number, "action_type": action_type,
        "target_user_id": mapping.user_id(target), "performed_by": list(performed_by or []),
        "data": data or {}, "performed_at": performed_at, "category_code": category_code,
        "category_extra": category_extra, "updated_at": updated_at, "digest": digest,
    }


class Reader:
    def __init__(self, session, lyla):
        self.session = session
        self.lyla = lyla
        self.summary = collections.Counter()
        self.categories = None
        self.created = set()

    def run(self):
        with self.session() as conn:
            self.categories = categories.load(conn, self.lyla)
        self.lyla.commit()
        self.sync_cases()
        self.sync_orphans()
        self.sync_vanished_actions()
        self.sync_notes()
        self.lyla.commit()
        return self.summary

    def changed_cases(self):
        current = dict(self.lyla.execute(digests.CASES).fetchall())
        with self.session() as conn:
            known = store.digests(conn, CASES)
            waiting = {row[0] for row in conn.execute(WAITING_CASES).fetchall()}
        changed = [number for number, digest in sorted(current.items())
                   if number not in mapping.SKIPPED_CASES and known.get(str(number)) != digest
                   and number not in waiting]
        return changed, current

    def load(self, case_numbers):
        return Rows(
            {row[0]: row for row in self.lyla.execute(LYLA_CASES, (case_numbers,)).fetchall()},
            grouped(self.lyla.execute(LYLA_THREADS, (case_numbers,)).fetchall()),
            grouped(self.lyla.execute(LYLA_ASSIGNEES, (case_numbers,)).fetchall()),
            grouped([action_row(row) for row in
                     self.lyla.execute(LYLA_ACTIONS, (case_numbers,)).fetchall()], "case_number"),
        )

    def sync_cases(self):
        changed, current = self.changed_cases()
        if not changed:
            return
        log.info("lyla: %s case(s) changed in LYLA", len(changed))
        for part in chunks(changed):
            cases = {row[0]: row for row in self.lyla.execute(LYLA_CASES, (part,)).fetchall()}
            threads = grouped(self.lyla.execute(LYLA_THREADS, (part,)).fetchall())
            self.create_missing(part, cases, threads)
        for part in chunks(changed):
            rows = self.load(part)
            for number in part:
                if number not in rows.cases:
                    continue
                try:
                    with self.session() as conn:
                        store.as_lyla(conn)
                        entity = store.mapped(conn, CASES, number)
                        if entity and entity[1] != number:
                            store.put(conn, CASES, number, "cases", entity[1], current[number])
                            continue
                        if self.sync_case(conn, rows, number):
                            store.put(conn, CASES, number, "cases", number, current[number])
                except Exception:
                    log.exception("lyla: case %s could not be read from LYLA", number)
                    self.summary["failed"] += 1

    def create_missing(self, case_numbers, cases, threads):
        with self.session() as conn:
            existing = {row[0] for row in conn.execute(EXISTING_CASES, (case_numbers,)).fetchall()}
            existing |= {int(key) for key in store.digests(conn, CASES)}
        for number in case_numbers:
            if number in existing or number not in cases:
                continue
            primary = next((row for row in threads.get(number, []) if row[3]), None)
            with self.session() as conn:
                store.as_lyla(conn)
                owner = None
                if primary:
                    row = conn.execute(THREAD_OWNER, {"channel": primary[1], "ts": primary[2]}).fetchone()
                    owner = row[0] if row else None
                if owner is not None and owner != number:
                    store.put(conn, CASES, number, "cases", owner)
                    self.merge_alias(number, owner)
                    self.summary["aliased"] += 1
                    continue
                opened_at = mapping.from_ms(cases[number][2])
                conn.execute(INSERT_CASE, (
                    number, LYLA_BOT_USER_ID, opened_at, opened_at, f"lyla:case:{number}",
                    primary[1] if primary else None, primary[2] if primary else None,
                ))
                self.created.add(number)
                self.summary["cases"] += 1

    def merge_alias(self, number, owner):
        writer.merge_into(self.lyla, number, owner, keep_primary=True)
        self.lyla.commit()
        log.info("lyla: LYLA case %s is Nemo case %s, merged it there", number, owner)

    def sync_case(self, conn, rows, number):
        case = rows.cases[number]
        nemo = conn.execute(NEMO_CASE, (number,)).fetchone()
        if nemo is None:
            return False
        self.sync_threads(conn, number, rows.threads.get(number, []))
        self.sync_assignees(conn, number, case, rows.assignees.get(number, []))
        for action in rows.actions.get(number, []):
            self.sync_action(conn, number, action)
        return self.sync_status(conn, case, nemo)

    def sync_threads(self, conn, case_id, threads):
        cards = {tuple(row) for row in conn.execute(CARD_THREADS, {"case_id": case_id}).fetchall()}
        for _number, channel_id, thread_ts, primary, added_at in threads:
            key = mapping.thread_key(channel_id, thread_ts)
            known = store.mapped(conn, THREADS, key)
            if known is None or known[1] != case_id:
                store.put(conn, THREADS, key, "cases", case_id)
                store.touch_case(conn, case_id)
            if primary or (channel_id, thread_ts) in cards:
                continue
            conn.execute(ADD_THREAD, (case_id, channel_id, thread_ts, LYLA_BOT_USER_ID,
                                      mapping.from_ms(added_at)))

    def sync_assignees(self, conn, case_id, case, assignees):
        wanted = {row[1]: row for row in assignees}
        present = {row[0] for row in conn.execute(NEMO_ASSIGNEES, (case_id,)).fetchall()}
        for user_id, (_number, _user, assigned_at, source) in wanted.items():
            if user_id in present:
                continue
            by = user_id if source == "self" else LYLA_BOT_USER_ID
            if conn.execute(ADD_ASSIGNEE, (case_id, user_id, mapping.from_ms(assigned_at), by)).fetchone():
                store.record(conn, "assignee", case_id, "attached", by, after={"user_id": user_id})
                self.summary["assignees"] += 1
        if case[1] == mapping.MERGED:
            return
        for user_id in present - set(wanted):
            row = conn.execute(REMOVE_ASSIGNEE, (case_id, user_id)).fetchone()
            if row:
                store.record(conn, "assignee", case_id, "detached", LYLA_BOT_USER_ID,
                             before={"user_id": user_id, "assigned_by": row[0]})
                self.summary["unassigned"] += 1

    def target_case(self, conn, merged_into):
        if merged_into is None:
            return None
        entity = store.mapped(conn, CASES, merged_into)
        if entity:
            return entity[1]
        row = conn.execute(EXISTING_CASES, ([merged_into],)).fetchone()
        return row[0] if row else None

    def sync_status(self, conn, case, nemo):
        number, status, created_at, resolved_at, resolved_by, _kind, merged_into = case
        case_id, nemo_resolved_at, resolution, duplicate_of, opened_at = nemo[:5]
        if status == mapping.EXPIRED:
            return True
        current = mapping.lyla_status(nemo_resolved_at, resolution)
        target = self.target_case(conn, merged_into) if status == mapping.MERGED else None
        if target is not None:
            target = merges.root(conn, target)
        if target == case_id:
            target = None

        if status == current and (status != mapping.MERGED or duplicate_of == target):
            if status in (mapping.RESOLVED, mapping.CANCELED):
                self.check_resolver(conn, case_id, resolved_by, nemo_resolved_at)
            return True

        if status == mapping.OPEN:
            if duplicate_of is not None:
                merges.unmerge(conn, case_id, LYLA_BOT_USER_ID, source_app=store.LYLA)
            conn.execute(REOPEN, (case_id,))
            conn.execute(REOPEN_REPORTS, (case_id,))
            store.record(conn, "case", case_id, "reopened", LYLA_BOT_USER_ID,
                         before={"resolution": resolution},
                         after={"resolved_at": None, "resolution": None})
            self.summary["reopened"] += 1
            return True

        live = conn.execute(LIVE_ACTION_COUNT, (case_id,)).fetchone()[0]
        new_resolution = mapping.resolution_for(status, live > 0)
        fallback = opened_at if case_id in self.created else dt.datetime.now(dt.UTC)
        at = mapping.from_ms(resolved_at) or nemo_resolved_at or fallback
        by = mapping.user_id(resolved_by)
        conn.execute(RESOLVE, (at, new_resolution, target, case_id))
        if current == mapping.OPEN:
            conn.execute(CLOSE_REPORTS, (at, by or LYLA_BOT_USER_ID, case_id))
        store.record(conn, "case", case_id, "resolved", by,
                     before={"resolution": resolution, "duplicate_of": duplicate_of},
                     after={"resolution": new_resolution, "duplicate_of": target}, at=at)
        self.summary["resolved"] += 1
        return True

    def check_resolver(self, conn, case_id, resolved_by, resolved_at):
        row = conn.execute(RESOLVER, (case_id,)).fetchone()
        resolver = row[0] if row else None
        if resolver and resolver != resolved_by:
            writer.set_resolver(self.lyla, case_id, resolver, resolved_at)
            self.lyla.commit()
            self.summary["resolvers"] += 1

    def sync_action(self, conn, case_id, action):
        if action["id"] in mapping.SKIPPED_ACTIONS:
            return None
        entity = store.mapped(conn, ACTIONS, action["id"])
        if entity and entity[2] == action["digest"]:
            return entity
        if entity and entity[0] == "notes":
            self.update_case_note(conn, entity[1], action)
        elif entity:
            self.update_actions(conn, entity[1], action)
        else:
            entity = self.import_action(conn, case_id, action)
        if entity:
            store.put(conn, ACTIONS, action["id"], entity[0], entity[1], action["digest"])
        return entity

    def parsed(self, action):
        has_end = bool(action["data"].get("banUntil"))
        return mapping.parse_action_type(action["action_type"], has_end)

    def action_values(self, action, type_key):
        data = action["data"]
        performers = [mapping.user_id(one) for one in action["performed_by"]]
        performers = [one for one in performers if one]
        details = {}
        if type_key == "channel_ban" and data.get("channelBanChannel"):
            details["channel_id"] = data["channelBanChannel"]
        if action["category_extra"]:
            details["category_extra"] = action["category_extra"]
        expires_at = (mapping.expiry_from(data.get("banUntil"))
                      if type_key in mapping.EXPIRING_TYPES else None)
        return {
            "target_user_id": action["target_user_id"],
            "reason": (data.get("whatTheyDid") or "").strip() or None,
            "resolved_by": performers,
            "performer": performers[0] if performers else LYLA_BOT_USER_ID,
            "category_key": self.categories.key_for(action["category_code"]),
            "expires_at": expires_at,
            "details": details,
        }

    def group_imported(self, conn, lyla_id):
        conn.execute(GROUP_IMPORTED, {"prefix": f"lyla:action:{lyla_id}:%"})

    def import_action(self, conn, case_id, action):
        types, solution = self.parsed(action)
        types = [(key, reversed_) for key, reversed_ in types
                 if action["target_user_id"] or key == "locked_thread"]
        performed_at = mapping.from_ms(action["performed_at"])
        if not types:
            return self.import_note(conn, case_id, action, performed_at)
        first = None
        for type_key, reversed_ in types:
            values = self.action_values(action, type_key)
            row = conn.execute(INSERT_ACTION, (
                case_id, type_key, values["target_user_id"], values["performer"],
                values["performer"], performed_at, values["expires_at"],
                performed_at if reversed_ else None,
                values["performer"] if reversed_ else None,
                REVERSED_IN_LYLA if reversed_ else None,
                Jsonb(values["details"]), f"lyla:action:{action['id']}:{type_key}",
                values["reason"], values["category_key"], solution, values["resolved_by"],
            )).fetchone()
            if row and first is None:
                first = row[0]
            self.summary["actions"] += 1
        if len(types) > 1:
            self.group_imported(conn, action["id"])
        if action["target_user_id"]:
            conn.execute(ADD_SUBJECT, (case_id, action["target_user_id"]))
        return ("actions", first) if first else None

    def import_note(self, conn, case_id, action, performed_at):
        body = "\n\n".join(one for one in (
            (action["data"].get("whatTheyDid") or "").strip(), (action["action_type"] or "").strip(),
        ) if one)
        author = self.action_values(action, None)["performer"]
        row = conn.execute(INSERT_CASE_NOTE, (
            case_id, body or "-", author, performed_at, performed_at, f"lyla:action:{action['id']}",
        )).fetchone()
        self.summary["case_notes"] += 1
        return ("notes", row[0]) if row else None

    def linked(self, conn, lyla_id, entity_id):
        return conn.execute(LINKED_ACTIONS, (f"lyla:action:{lyla_id}:%", entity_id)).fetchall()

    def update_actions(self, conn, entity_id, action):
        linked = self.linked(conn, action["id"], entity_id)
        if not linked:
            return
        case_id = linked[0][11]
        current = [(row[1], row[9] is not None) for row in linked]
        solution = linked[0][4]
        retyped = mapping.compose_action_type(current, solution) != (action["action_type"] or "").strip()
        types, parsed_solution = self.parsed(action) if retyped else (current, solution)
        wanted = dict(types)
        at = mapping.from_ms(action["updated_at"]) or mapping.from_ms(action["performed_at"])

        for row in linked:
            action_id, type_key, reversed_at = row[0], row[1], row[9]
            if reversed_at is not None:
                continue
            if type_key not in wanted:
                self.reverse(conn, action_id, at, REMOVED_IN_LYLA)
                continue
            if wanted[type_key]:
                self.reverse(conn, action_id, at, REVERSED_IN_LYLA)
                continue
            self.update_action(conn, row, action, parsed_solution)

        present = {row[1] for row in linked}
        for type_key, reversed_ in types:
            if type_key in present or reversed_:
                continue
            if not action["target_user_id"] and type_key != "locked_thread":
                continue
            values = self.action_values(action, type_key)
            conn.execute(INSERT_ACTION, (
                case_id, type_key, values["target_user_id"], values["performer"],
                values["performer"], mapping.from_ms(action["performed_at"]), values["expires_at"],
                None, None, None, Jsonb(values["details"]), f"lyla:action:{action['id']}:{type_key}",
                values["reason"], values["category_key"], parsed_solution, values["resolved_by"],
            ))
            self.summary["actions"] += 1
        self.group_imported(conn, action["id"])

    def update_action(self, conn, row, action, solution):
        (action_id, type_key, target, reason, old_solution, resolved_by, category_key, expires_at,
         details, _reversed_at, performed_by, _case_id) = row
        values = self.action_values(action, type_key)
        resolvers = list(resolved_by or []) or [performed_by]
        new = {
            "target_user_id": values["target_user_id"] or target,
            "reason": values["reason"] if values["reason"] is not None else reason,
            "solution": solution,
            "resolved_by": values["resolved_by"] or resolvers,
            "category_key": (values["category_key"] if action["category_code"] is not None
                             else category_key),
            "expires_at": expires_at,
            "details": dict(details or {}),
        }
        if type_key in mapping.EXPIRING_TYPES and not mapping.same_day(
                expires_at, action["data"].get("banUntil")):
            new["expires_at"] = values["expires_at"]
        if values["details"].get("channel_id"):
            new["details"]["channel_id"] = values["details"]["channel_id"]
        if action["category_extra"]:
            new["details"]["category_extra"] = action["category_extra"]
        old = {
            "target_user_id": target, "reason": reason, "solution": old_solution,
            "resolved_by": resolvers, "category_key": category_key, "expires_at": expires_at,
            "details": dict(details or {}),
        }
        if new == old:
            return False
        conn.execute(UPDATE_ACTION, (
            new["target_user_id"], new["reason"], new["solution"], new["resolved_by"],
            new["category_key"], new["expires_at"], Jsonb(new["details"]), action_id,
        ))
        changed = {key for key in new if new[key] != old[key]}
        store.record(conn, "action", action_id, "edited", LYLA_BOT_USER_ID,
                     before={key: old[key] for key in changed},
                     after={key: new[key] for key in changed})
        self.summary["edited"] += 1
        return True

    def reverse(self, conn, action_id, at, why):
        if conn.execute(REVERSE_ACTION, (at, LYLA_BOT_USER_ID, why, action_id)).fetchone():
            store.record(conn, "action", action_id, "reversed", LYLA_BOT_USER_ID,
                         after={"reason": why})
            self.summary["reversed"] += 1

    def update_case_note(self, conn, note_id, action):
        body = "\n\n".join(one for one in (
            (action["data"].get("whatTheyDid") or "").strip(), (action["action_type"] or "").strip(),
        ) if one)
        row = conn.execute(NOTE, (note_id,)).fetchone()
        if row and row[1] != body and body:
            conn.execute(EDIT_NOTE, (body, mapping.from_ms(action["updated_at"]),
                                     LYLA_BOT_USER_ID, note_id))
            self.summary["notes_edited"] += 1

    def sync_orphans(self):
        current = dict(self.lyla.execute(digests.ORPHAN_ACTIONS).fetchall())
        with self.session() as conn:
            known = store.digests(conn, ACTIONS)
        changed = sorted(action_id for action_id, digest in current.items()
                         if action_id not in mapping.SKIPPED_ACTIONS
                         and known.get(str(action_id)) != digest)
        if not changed:
            return
        log.info("lyla: %s action(s) without a case changed in LYLA", len(changed))
        for part in chunks(changed):
            for row in self.lyla.execute(LYLA_ACTIONS_BY_ID, (part,)).fetchall():
                action = action_row(row)
                try:
                    self.sync_orphan(action)
                except Exception:
                    log.exception("lyla: action %s could not be read from LYLA", action["id"])
                    self.summary["failed"] += 1

    def sync_orphan(self, action):
        with self.session() as conn:
            store.as_lyla(conn)
            entity = store.mapped(conn, ACTIONS, action["id"])
            if entity:
                self.sync_action(conn, None, action)
                return
            thread = mapping.thread_of(action["data"].get("permalink"))
            case_id = self.thread_case(conn, thread)
        if case_id is None:
            with self.session() as conn:
                numbers.refill(conn, self.lyla)
            case_id = self.open_closed_case(action, thread)
        with self.session() as conn:
            store.as_lyla(conn)
            self.sync_action(conn, case_id, action)

    def thread_case(self, conn, thread):
        if thread is None:
            return None
        row = conn.execute(THREAD_OWNER, {"channel": thread[0], "ts": thread[1]}).fetchone()
        return row[0] if row else None

    def open_closed_case(self, action, thread):
        performed_at = mapping.from_ms(action["performed_at"])
        performers = [mapping.user_id(one) for one in action["performed_by"]]
        opener = next((one for one in performers if one), LYLA_BOT_USER_ID)
        channel_id, thread_ts = thread or (None, None)
        with self.session() as conn:
            store.as_nemo(conn)
            case_id = conn.execute(INSERT_THREAD_CASE, (
                opener, performed_at, performed_at,
                f"lyla:thread:{channel_id}:{thread_ts}" if thread else f"lyla:action-case:{action['id']}",
                channel_id, thread_ts,
            )).fetchone()[0]
            conn.execute(RESOLVE, (performed_at, mapping.ACTION_TAKEN, None, case_id))
            store.as_lyla(conn)
            store.record(conn, "case", case_id, "resolved", opener,
                         after={"resolution": mapping.ACTION_TAKEN}, at=performed_at)
            if thread:
                store.put(conn, THREADS, mapping.thread_key(*thread), "cases", case_id)
        self.summary["thread_cases"] += 1
        return case_id

    def sync_vanished_actions(self):
        present = {row[0] for row in self.lyla.execute(LYLA_ACTION_IDS).fetchall()}
        with self.session() as conn:
            known = store.digests(conn, ACTIONS)
        gone = sorted(int(key) for key in known if int(key) not in present)
        for lyla_id in gone:
            with self.session() as conn:
                store.as_lyla(conn)
                entity = store.mapped(conn, ACTIONS, lyla_id)
                if entity and entity[0] == "notes":
                    conn.execute(DELETE_NOTE, (LYLA_BOT_USER_ID, entity[1]))
                elif entity:
                    for row in self.linked(conn, lyla_id, entity[1]):
                        self.reverse(conn, row[0], None, DELETED_IN_LYLA)
                store.forget(conn, ACTIONS, lyla_id)

    def sync_notes(self):
        current = dict(self.lyla.execute(digests.NOTES).fetchall())
        with self.session() as conn:
            known = store.digests(conn, NOTES)
            waiting = {row[0] for row in conn.execute(WAITING_NOTES).fetchall()}
        changed = sorted(note_id for note_id, digest in current.items()
                         if known.get(str(note_id)) != digest)
        for row in self.lyla.execute(LYLA_NOTES, (changed,)).fetchall() if changed else []:
            note_id = row[0]
            with self.session() as conn:
                store.as_lyla(conn)
                entity = store.mapped(conn, NOTES, note_id)
                if entity and entity[1] in waiting:
                    continue
                entity_id = self.sync_note(conn, entity, row)
                if entity_id:
                    store.put(conn, NOTES, note_id, "notes", entity_id, row[7])
        for key in sorted(set(known) - {str(one) for one in current}):
            with self.session() as conn:
                store.as_lyla(conn)
                entity = store.mapped(conn, NOTES, key)
                if entity and entity[1] in waiting:
                    continue
                if entity:
                    conn.execute(DELETE_NOTE, (LYLA_BOT_USER_ID, entity[1]))
                    self.summary["notes_deleted"] += 1
                store.forget(conn, NOTES, key)

    def sync_note(self, conn, entity, row):
        note_id, target, body, created_by, created_at, edited_by, edited_at, _digest = row
        if entity is None:
            inserted = conn.execute(INSERT_MEMBER_NOTE, (
                mapping.user_id(target), body, created_by, mapping.from_ms(created_at),
                mapping.from_ms(edited_at or created_at), mapping.from_ms(edited_at),
                edited_by if edited_at else None, f"lyla:note:{note_id}",
            )).fetchone()
            self.summary["notes"] += 1
            return inserted[0] if inserted else None
        current = conn.execute(NOTE, (entity[1],)).fetchone()
        if current and current[1] != body:
            conn.execute(EDIT_NOTE, (body, mapping.from_ms(edited_at), edited_by or LYLA_BOT_USER_ID,
                                     entity[1]))
            store.record(conn, "note", entity[1], "edited", edited_by or LYLA_BOT_USER_ID,
                         before={"body": current[1]}, after={"body": body})
            self.summary["notes_edited"] += 1
        return entity[1]

