from bot.nemo.cards import action, report

ROWS = 8

COUNTS = """
SELECT
  (SELECT count(*) FROM fd.case_participants
   WHERE user_id = %(who)s AND role = 'subject') AS subject_of,
  (SELECT count(DISTINCT case_id) FROM fd.case_participants
   WHERE user_id = %(who)s) AS logged_in,
  (SELECT count(*) FROM fd.actions
   WHERE target_user_id = %(who)s AND reversed_at IS NULL) AS live,
  (SELECT count(*) FROM fd.actions
   WHERE target_user_id = %(who)s AND reversed_at IS NOT NULL) AS reversed
"""

IN_FORCE = """
SELECT type_key, expires_at, details
FROM fd.actions
WHERE target_user_id = %(who)s
  AND reversed_at IS NULL
  AND (expires_at IS NULL OR expires_at > now())
ORDER BY array_position(%(worst_first)s::text[], type_key), performed_at DESC
LIMIT 1
"""

ENTRIES = """
WITH entries AS (
  SELECT c.opened_at AS at, 'cases' AS kind, c.id AS case_id,
         c.category_key AS what, c.resolution AS who_by, NULL::text AS said
  FROM fd.cases c
  JOIN fd.case_participants p ON p.case_id = c.id AND p.role = 'subject'
  WHERE p.user_id = %(who)s

  UNION ALL
  SELECT a.performed_at, 'actions', a.case_id, a.type_key, a.performed_by, NULL::text
  FROM fd.actions a
  WHERE a.target_user_id = %(who)s

  UNION ALL
  SELECT a.reversed_at, 'reversed', a.case_id, a.type_key, a.reversed_by, a.reversal_reason
  FROM fd.actions a
  WHERE a.target_user_id = %(who)s AND a.reversed_at IS NOT NULL

  UNION ALL
  SELECT n.created_at, 'notes', NULL::bigint, NULL::text, n.author, n.body
  FROM fd.notes n
  WHERE n.subject_user_id = %(who)s AND n.deleted_at IS NULL
)
SELECT count(*) OVER () AS total, at, kind, case_id, what, who_by, said
FROM entries
ORDER BY at DESC
LIMIT %(rows)s
"""


def worst_first():
    table = action.table()
    return sorted(table, key=lambda key: table[key]["weight"])


def read(conn, user_id, rows=ROWS):
    counts = conn.execute(COUNTS, {"who": user_id}).fetchone()
    standing = conn.execute(
        IN_FORCE, {"who": user_id, "worst_first": worst_first()}
    ).fetchone()
    found = conn.execute(ENTRIES, {"who": user_id, "rows": rows}).fetchall()

    return {
        "user_id": user_id,
        "counts": {
            "subject_of": counts[0],
            "logged_in": counts[1],
            "live": counts[2],
            "reversed": counts[3],
        },
        "in_force": (
            {"type_key": standing[0], "expires_at": standing[1], "details": standing[2]}
            if standing
            else None
        ),
        "total": found[0][0] if found else 0,
        "entries": [
            {
                "at": row[1],
                "kind": row[2],
                "case_id": row[3],
                "what": row[4],
                "who_by": row[5],
                "said": row[6],
            }
            for row in found
        ],
    }


def when(at):
    return at.strftime("%-d %b %Y") if at else "n/a"


def counted(counts):
    parts = [
        f"subject of {counts['subject_of']}",
        f"logged in {counts['logged_in']}",
        f"{counts['live']} action" + ("s" if counts["live"] != 1 else ""),
    ]
    if counts["reversed"]:
        parts.append(f"{counts['reversed']} reversed")
    return "  ·  ".join(parts)


def standing_line(found):
    if found is None:
        return "nothing standing"

    said = action.label(found["type_key"]).lower()
    where = (found.get("details") or {}).get("channel_id")
    if where:
        said += f" in <#{where}>"
    if found.get("expires_at"):
        said += f" until {found['expires_at'].strftime('%-d %b')}"
    else:
        said += ", no end date"
    return said


def line(entry):
    at = when(entry["at"])
    if entry["kind"] == "cases":
        what = report.category_label(entry["what"]) or "not set"
        ending = f", {entry['who_by'].replace('_', ' ')}" if entry["who_by"] else ", open"
        return f"{at}  ·  case {entry['case_id']}, {what.lower()}{ending}"

    if entry["kind"] == "actions":
        return (
            f"{at}  ·  {action.label(entry['what']).lower()}"
            f" on case {entry['case_id']}, by <@{entry['who_by']}>"
        )

    if entry["kind"] == "reversed":
        said = f"{at}  ·  {action.label(entry['what']).lower()} reversed by <@{entry['who_by']}>"
        return f"{said}, {entry['said']}" if entry["said"] else said

    return f"{at}  ·  note by <@{entry['who_by']}>: {entry['said']}"
