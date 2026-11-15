from bot.core import audit
from bot.core.case import reopen_reports

LIVE_MERGE = """
SELECT id, into_case_id, prior_resolved_at, prior_resolution
FROM fd.case_merges WHERE case_id = %s AND unmerged_at IS NULL
"""

LOCK_CASE = "SELECT duplicate_of, resolved_at, resolution FROM fd.cases WHERE id = %s FOR UPDATE"

UNMERGE = """
UPDATE fd.cases SET duplicate_of = NULL, resolved_at = %s, resolution = %s, updated_at = now()
WHERE id = %s
RETURNING resolved_at, resolution
"""

FAMILY = """
WITH RECURSIVE family(id) AS (
    SELECT %s::bigint
    UNION
    SELECT c.id FROM fd.cases c JOIN family f ON c.duplicate_of = f.id
)
SELECT id FROM family ORDER BY id
"""

COPY_TAGS = """
INSERT INTO fd.case_tags (case_id, tag_id, added_by, merge_id)
SELECT DISTINCT ON (s.tag_id) %(target)s, s.tag_id, %(by)s, m.id
FROM fd.case_tags s
JOIN fd.case_merges m ON m.case_id = s.case_id AND m.into_case_id = %(target)s AND m.unmerged_at IS NULL
WHERE s.case_id = ANY(%(sources)s)
  AND NOT EXISTS (SELECT 1 FROM fd.case_tags t WHERE t.case_id = %(target)s AND t.tag_id = s.tag_id)
ORDER BY s.tag_id, s.case_id, s.added_at
ON CONFLICT DO NOTHING
RETURNING tag_id
"""

TAG_NAMES = "SELECT name FROM fd.tags WHERE id = ANY(%s) ORDER BY name"

COPIED_TAGS = """
SELECT ct.tag_id, t.name FROM fd.case_tags ct JOIN fd.tags t ON t.id = ct.tag_id
WHERE ct.case_id = %s AND ct.merge_id = %s
ORDER BY t.name
"""

TAG_KEEPER = """
SELECT m.id FROM fd.case_merges m
WHERE m.into_case_id = %s AND m.unmerged_at IS NULL AND m.id <> %s
  AND EXISTS (SELECT 1 FROM fd.case_tags t WHERE t.case_id = m.case_id AND t.tag_id = %s)
ORDER BY m.id
LIMIT 1
"""

KEEP_TAG = "UPDATE fd.case_tags SET merge_id = %s WHERE case_id = %s AND tag_id = %s"

DROP_TAG = "DELETE FROM fd.case_tags WHERE case_id = %s AND tag_id = %s"


ROOT = """
WITH RECURSIVE chain(id, parent, depth) AS (
    SELECT id, duplicate_of, 0 FROM fd.cases WHERE id = %s
    UNION ALL
    SELECT c.id, c.duplicate_of, chain.depth + 1 FROM fd.cases c JOIN chain ON c.id = chain.parent
    WHERE chain.depth < 50
)
SELECT id FROM chain WHERE parent IS NULL
"""


def root(conn, case_id):
    row = conn.execute(ROOT, (case_id,)).fetchone()
    return row[0] if row else case_id


def stamp(value):
    return str(value) if value else None


def family(conn, case_id):
    return [row[0] for row in conn.execute(FAMILY, (case_id,)).fetchall()]


def copy_tags(conn, target_id, source_ids, by, source_app=audit.SOURCE_APP):
    if not source_ids:
        return []
    tag_ids = [row[0] for row in conn.execute(
        COPY_TAGS, {"target": target_id, "sources": list(source_ids), "by": by}).fetchall()]
    if not tag_ids:
        return []
    names = [row[0] for row in conn.execute(TAG_NAMES, (tag_ids,)).fetchall()]
    audit.record(conn, "case_tag", target_id, "added", by, source_app=source_app,
                 after={"tags": names, "source_case_ids": list(source_ids)})
    return names


def release_tags(conn, into_case_id, merge_id):
    removed = []
    for tag_id, name in conn.execute(COPIED_TAGS, (into_case_id, merge_id)).fetchall():
        keeper = conn.execute(TAG_KEEPER, (into_case_id, merge_id, tag_id)).fetchone()
        if keeper:
            conn.execute(KEEP_TAG, (keeper[0], into_case_id, tag_id))
        else:
            conn.execute(DROP_TAG, (into_case_id, tag_id))
            removed.append(name)
    return removed


def audit_released(conn, into_case_id, case_id, removed, by, source_app=audit.SOURCE_APP):
    if removed:
        audit.record(conn, "case_tag", into_case_id, "removed", by, source_app=source_app,
                     before={"tags": removed, "source_case_ids": [case_id]})


def release_previous(conn, case_id, by, source_app=audit.SOURCE_APP):
    merge = conn.execute(LIVE_MERGE, (case_id,)).fetchone()
    if merge is None:
        return []
    removed = release_tags(conn, merge[1], merge[0])
    audit_released(conn, merge[1], case_id, removed, by, source_app)
    return removed


def unmerge(conn, case_id, by, source_app=audit.SOURCE_APP):
    row = conn.execute(LOCK_CASE, (case_id,)).fetchone()
    if row is None or row[0] is None:
        return None
    into_case_id, resolved_at, resolution = row
    merge = conn.execute(LIVE_MERGE, (case_id,)).fetchone()
    prior = (None, None)
    if merge is not None and merge[2] is not None and merge[3] is not None:
        prior = (merge[2], merge[3])
    after = conn.execute(UNMERGE, (*prior, case_id)).fetchone()
    removed = release_tags(conn, into_case_id, merge[0]) if merge else []

    audit.record(conn, "case", case_id, "unmerged", by, source_app=source_app,
                 before={"resolved_at": stamp(resolved_at), "resolution": resolution,
                         "duplicate_of": into_case_id},
                 after={"resolved_at": stamp(after[0]), "resolution": after[1], "duplicate_of": None})
    audit_released(conn, into_case_id, case_id, removed, by, source_app)

    reopened = after[0] is None
    if reopened:
        for member_id in family(conn, case_id):
            reopen_reports(conn, member_id, by)
    return {"into_case_id": into_case_id, "reopened": reopened, "removed_tags": removed}
