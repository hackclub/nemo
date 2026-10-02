UPDATE fd.access_grants
SET granted_by = 'manually'
WHERE granted_by = 'backfill';
