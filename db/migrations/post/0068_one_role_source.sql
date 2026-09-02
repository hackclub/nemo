CREATE OR REPLACE VIEW app.effective_role AS
SELECT s.user_id::text AS user_id, 'community_manager'::text AS role
FROM app.staff s WHERE s.community_manager
UNION
SELECT a.user_id::text,
       (CASE a.role WHEN 'lead' THEN 'firefighter' ELSE a.role END)::text
FROM fd.access_grants a
WHERE a.revoked_at IS NULL AND a.role IN ('firefighter', 'lead')
UNION
SELECT c.user_id::text, 'community_manager'::text
FROM app.community_grants c
WHERE c.revoked_at IS NULL AND c.family = 'read' AND c.role = 'curator'
UNION
SELECT g.user_id, g.name
FROM app.grant g WHERE g.kind = 'role' AND g.revoked_at IS NULL;

DO $$
BEGIN
    EXECUTE 'GRANT SELECT ON app.effective_role TO rails_app';
    EXECUTE 'GRANT SELECT ON app.effective_role TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN NULL;
END
$$;
