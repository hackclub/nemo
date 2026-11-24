ALTER TABLE fd.member_guards ADD COLUMN lift_only boolean NOT NULL DEFAULT false;

UPDATE fd.member_guards
SET lift_only = true
WHERE kind = 'deactivation'
  AND reason = 'Deactivated outside Nemo'
  AND case_id IS NULL
  AND state IN ('lifting', 'lifted');
