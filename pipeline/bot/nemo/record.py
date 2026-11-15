from bot.core.formatting import short_end
from bot.nemo import channel
from bot.nemo.views import action, member_view

ACTIONS_LIMIT = 3
NOTES_LIMIT = 2

COUNTS = """
SELECT
  (SELECT count(DISTINCT case_id) FROM fd.case_participants
   WHERE user_id = %(user_id)s) AS case_count,
  (SELECT count(DISTINCT p.case_id) FROM fd.case_participants p
   JOIN fd.cases c ON c.id = p.case_id
   WHERE p.user_id = %(user_id)s AND c.resolved_at IS NULL) AS open_case_count,
  (SELECT count(*) FROM fd.actions
   WHERE target_user_id = %(user_id)s) AS action_count,
  (SELECT count(*) FROM fd.actions
   WHERE target_user_id = %(user_id)s AND reversed_at IS NOT NULL) AS reversed_action_count,
  (SELECT count(*) FROM fd.notes
   WHERE subject_user_id = %(user_id)s AND deleted_at IS NULL) AS note_count
"""

IN_FORCE = """
SELECT kind, expires_at, channel_id, case_id, enforcement_status, enforced_by
FROM fd.member_guards
WHERE subject_id = %(user_id)s AND state IN ('live', 'lifting')
ORDER BY array_position(%(worst_first)s::text[], kind), opened_at DESC
LIMIT 1
"""

RECENT_ACTIONS = """
SELECT type_key, case_id, performed_by, performed_at, expires_at, reason,
       reversed_at, reversed_by, reversal_reason, details
FROM fd.actions
WHERE target_user_id = %(user_id)s
ORDER BY performed_at DESC, id DESC
LIMIT %(limit)s
"""

RECENT_NOTES = """
SELECT author, body, created_at
FROM fd.notes
WHERE subject_user_id = %(user_id)s AND deleted_at IS NULL
ORDER BY created_at DESC, id DESC
LIMIT %(limit)s
"""


def worst_first():
    table = action.table()
    return sorted(table, key=lambda key: table[key]["weight"])


def read(conn, user_id, actions_limit=ACTIONS_LIMIT, notes_limit=NOTES_LIMIT):
    counts = conn.execute(COUNTS, {"user_id": user_id}).fetchone()
    in_force_row = conn.execute(
        IN_FORCE, {"user_id": user_id, "worst_first": worst_first()}
    ).fetchone()
    action_rows = conn.execute(RECENT_ACTIONS, {"user_id": user_id, "limit": actions_limit}).fetchall()
    note_rows = conn.execute(RECENT_NOTES, {"user_id": user_id, "limit": notes_limit}).fetchall()

    return {
        "user_id": user_id,
        "counts": {
            "case_count": counts[0],
            "open_case_count": counts[1],
            "action_count": counts[2],
            "reversed_action_count": counts[3],
            "note_count": counts[4],
        },
        "in_force": (
            {
                "kind": in_force_row[0],
                "expires_at": in_force_row[1],
                "channel_id": in_force_row[2],
                "case_id": in_force_row[3],
                "enforcement_status": in_force_row[4],
                "enforced_by": in_force_row[5],
            }
            if in_force_row
            else None
        ),
        "actions": [
            {
                "type_key": row[0],
                "case_id": row[1],
                "performed_by": row[2],
                "performed_at": row[3],
                "expires_at": row[4],
                "reason": row[5],
                "reversed_at": row[6],
                "reversed_by": row[7],
                "reversal_reason": row[8],
                "channel_id": (row[9] or {}).get("channel_id"),
            }
            for row in action_rows
        ],
        "notes": [{"author": row[0], "body": row[1], "created_at": row[2]} for row in note_rows],
    }


def counts_line(counts):
    parts = []
    for key, one, many in (("case_count", "case", "cases"), ("action_count", "action", "actions")):
        if counts[key]:
            parts.append(f"{counts[key]} {one if counts[key] == 1 else many}")
            if key == "case_count" and counts["open_case_count"]:
                parts.append(f"{counts['open_case_count']} open")
            if key == "action_count" and counts["reversed_action_count"]:
                parts.append(f"{counts['reversed_action_count']} reversed")
    if counts["note_count"]:
        parts.append(f"{counts['note_count']} {'note' if counts['note_count'] == 1 else 'notes'}")
    return ", ".join(parts) if parts else "No record"


ENFORCEMENT_STATUS_LABELS = {
    "pending": "pending",
    "failed": "not enforced",
}


def in_force_line(guard):
    if guard is None:
        return "nothing active"

    text = action.label(guard["kind"]).lower()
    where = guard.get("channel_id")
    if where:
        text += f" in <#{where}>"
    if guard.get("expires_at"):
        text += f" until {short_end(guard['expires_at'])}"
    else:
        text += ", no end date"

    if guard.get("enforced_by") == "by_hand":
        return f"{text}, manual"
    if guard.get("enforced_by") == "firehose":
        return f"{text}, Firehose"
    status_label = ENFORCEMENT_STATUS_LABELS.get(guard.get("enforcement_status"))
    return f"{text}, {status_label}" if status_label else text


def active_line(guard):
    line = in_force_line(guard)
    line = line[:1].upper() + line[1:]
    if guard and guard.get("case_id"):
        line += f", case {guard['case_id']}"
    return line


def build_view(conn, user_id, can_note=False):
    member_record = read(conn, user_id)
    return member_view.build_view(
        user_id,
        active_line(member_record["in_force"]),
        counts_line(member_record["counts"]),
        member_record["actions"],
        member_record["notes"],
        channel.member_url(user_id),
        can_note,
        channel.case_url,
        lambda case_id: channel.thread_url(conn, case_id),
    )
