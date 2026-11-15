from bot.nemo import case_actions, profile

CASE_FACTS = """
SELECT c.duplicate_of,
       greatest(
           c.updated_at,
           coalesce((SELECT max(a.assigned_at) FROM fd.case_assignees a WHERE a.case_id = c.id), c.updated_at),
           coalesce((SELECT max(x.performed_at) FROM fd.actions x WHERE x.case_id = c.id), c.updated_at)
       ),
       (SELECT u.actor_user_id FROM fd.audit u
         WHERE u.entity_type = 'case' AND u.entity_id = c.id AND u.verb = 'resolved'
         ORDER BY u.occurred_at DESC, u.id DESC LIMIT 1)
FROM fd.cases c
WHERE c.id = %s
"""


def enrich(client, conn, case, url_of=None, thread_of=None):
    row = conn.execute(CASE_FACTS, (case["case_id"],)).fetchone()
    if row:
        case["duplicate_of"], case["updated_at"], case["resolved_by"] = row
        if case["duplicate_of"] and url_of:
            case["duplicate_url"] = url_of(case["duplicate_of"])
        if case["duplicate_of"] and thread_of:
            case["duplicate_thread_url"] = thread_of(conn, case["duplicate_of"])
    case["actions"] = [one["type_key"] for one in case_actions.live_actions(conn, case["case_id"])]
    subjects = case.get("subjects") or []
    if client is not None and subjects:
        case["subject_icon"] = profile.profile(client, subjects[0])["icon"]
    return case
