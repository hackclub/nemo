UPDATE fd.access_grants
SET revoked_by = 'migration', revoked_at = now()
WHERE role = 'community_manager' AND revoked_at IS NULL;

UPDATE fd.role_permissions
SET role = 'lead'
WHERE role = 'community_manager'
  AND permission_key NOT IN (
      SELECT permission_key FROM fd.role_permissions WHERE role = 'lead'
  );

DELETE FROM fd.role_permissions WHERE role = 'community_manager';

ALTER TABLE fd.access_grants DROP CONSTRAINT access_grants_role_known;
ALTER TABLE fd.access_grants ADD CONSTRAINT access_grants_role_known CHECK (
    role IN ('firefighter', 'lead') OR revoked_at IS NOT NULL
);

ALTER TABLE fd.role_permissions DROP CONSTRAINT role_permissions_role_known;
ALTER TABLE fd.role_permissions ADD CONSTRAINT role_permissions_role_known CHECK (
    role IN ('firefighter', 'lead')
);
