from psycopg.types.json import Jsonb

SOURCE_APP = "nemo"

RECORD = """
INSERT INTO fd.audit
    (actor_user_id, actor_kind, entity_type, entity_id, verb, before, after, source_app,
     subject_user_id)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
"""


def record(conn, entity_type, entity_id, verb, actor, before=None, after=None,
           actor_kind="human", source_app=SOURCE_APP, subject_user_id=None):
    conn.execute(
        RECORD,
        (
            actor,
            actor_kind,
            entity_type,
            entity_id,
            verb,
            Jsonb(before) if before else None,
            Jsonb(after) if after else None,
            source_app,
            subject_user_id,
        ),
    )
