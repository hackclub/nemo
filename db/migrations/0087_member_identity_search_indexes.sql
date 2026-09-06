CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS member_identity_real_name_trgm_idx
    ON fd.member_identity USING gin (lower(real_name) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS member_identity_first_name_trgm_idx
    ON fd.member_identity USING gin (lower(first_name) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS member_identity_last_name_trgm_idx
    ON fd.member_identity USING gin (lower(last_name) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS member_identity_email_trgm_idx
    ON fd.member_identity USING gin (lower(email) gin_trgm_ops);
