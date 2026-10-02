ALTER TABLE api.consent DROP CONSTRAINT consent_pkey;

ALTER TABLE api.consent ALTER COLUMN app_id DROP NOT NULL;

CREATE UNIQUE INDEX consent_one_row_idx
    ON api.consent (user_id, capability, coalesce(app_id, 0));

DROP INDEX IF EXISTS api.consent_granted_idx;

CREATE INDEX consent_granted_idx ON api.consent (capability, app_id)
    WHERE state = 'granted';

ALTER TABLE api.consent_log ALTER COLUMN app_id DROP NOT NULL;
