ALTER TABLE fd.member_cluster ADD COLUMN IF NOT EXISTS conflict boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS member_cluster_conflict_idx ON fd.member_cluster (cluster_id) WHERE conflict;
