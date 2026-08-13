ALTER TABLE fd.cases DROP CONSTRAINT cases_claimed_together;
ALTER TABLE fd.cases DROP COLUMN claimed_by;
ALTER TABLE fd.cases DROP COLUMN claimed_at;
