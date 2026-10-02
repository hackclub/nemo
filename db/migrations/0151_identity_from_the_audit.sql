WITH said AS (
    SELECT DISTINCT ON (e.actor_id)
           e.actor_id AS user_id,
           nullif(btrim(e.payload #>> '{actor,user,email}'), '') AS email,
           nullif(btrim(e.payload #>> '{actor,user,name}'), '') AS real_name
    FROM slack.audit_event e
    JOIN fd.member m ON m.user_id = e.actor_id
    WHERE e.actor_kind = 'user'
      AND e.payload #>> '{actor,user,email}' IS NOT NULL
    ORDER BY e.actor_id, e.at DESC
)
INSERT INTO fd.member_identity (user_id, real_name, email, updated_at)
SELECT user_id, real_name, email, now() FROM said
ON CONFLICT (user_id) DO UPDATE SET
    email = coalesce(fd.member_identity.email, EXCLUDED.email),
    real_name = coalesce(fd.member_identity.real_name, EXCLUDED.real_name),
    updated_at = now()
WHERE fd.member_identity.purged_at IS NULL
  AND (fd.member_identity.email IS NULL OR fd.member_identity.real_name IS NULL);

CREATE INDEX IF NOT EXISTS audit_event_actor_email_idx
    ON slack.audit_event (actor_id, at DESC)
    WHERE actor_kind = 'user' AND payload #>> '{actor,user,email}' IS NOT NULL;
