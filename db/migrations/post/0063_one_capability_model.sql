CREATE TABLE IF NOT EXISTS app.capability (
    key text PRIMARY KEY,
    label text NOT NULL,
    area text NOT NULL,
    record_scope text,
    logged boolean NOT NULL DEFAULT false,
    every_account boolean NOT NULL DEFAULT false,
    locked boolean NOT NULL DEFAULT false,
    CONSTRAINT capability_scope_known
        CHECK (record_scope IS NULL OR record_scope IN ('assigned', 'author', 'channel'))
);

CREATE TABLE IF NOT EXISTS app.role (
    name text PRIMARY KEY,
    label text NOT NULL,
    everything boolean NOT NULL DEFAULT false,
    grantable boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS app.role_capability (
    role text NOT NULL REFERENCES app.role(name) ON DELETE CASCADE,
    capability text NOT NULL REFERENCES app.capability(key) ON DELETE CASCADE,
    PRIMARY KEY (role, capability)
);

CREATE TABLE IF NOT EXISTS app.grant (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id text NOT NULL,
    kind text NOT NULL,
    name text NOT NULL,
    effect text NOT NULL DEFAULT 'allow',
    granted_by text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    reason text,
    revoked_by text,
    revoked_at timestamptz,
    CONSTRAINT grant_kind_known CHECK (kind IN ('role', 'capability')),
    CONSTRAINT grant_effect_known CHECK (effect IN ('allow', 'deny')),
    CONSTRAINT grant_deny_is_a_capability CHECK (effect = 'allow' OR kind = 'capability'),
    CONSTRAINT grant_revoked_together CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS grant_one_live
    ON app.grant (user_id, kind, name) WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS grant_live_by_user
    ON app.grant (user_id) WHERE revoked_at IS NULL;

ALTER TABLE app.channel_grants ADD COLUMN IF NOT EXISTS role text;
ALTER TABLE app.channel_grants ALTER COLUMN user_id DROP NOT NULL;

DO $$
BEGIN
    ALTER TABLE app.channel_grants ADD CONSTRAINT channel_grants_one_subject
        CHECK ((user_id IS NULL) <> (role IS NULL));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS channel_grants_one_live_role
    ON app.channel_grants (role, channel_id) WHERE revoked_at IS NULL AND role IS NOT NULL;

CREATE OR REPLACE VIEW app.effective_capability AS
WITH held AS (
    SELECT g.user_id, g.name AS role
    FROM app.grant g
    WHERE g.kind = 'role' AND g.revoked_at IS NULL
),
superadmin AS (
    SELECT DISTINCT h.user_id
    FROM held h JOIN app.role r ON r.name = h.role
    WHERE r.everything
),
baseline AS (
    SELECT h.user_id, rc.capability
    FROM held h JOIN app.role_capability rc ON rc.role = h.role
),
added AS (
    SELECT g.user_id, g.name AS capability
    FROM app.grant g
    WHERE g.kind = 'capability' AND g.effect = 'allow' AND g.revoked_at IS NULL
),
denied AS (
    SELECT g.user_id, g.name AS capability
    FROM app.grant g
    WHERE g.kind = 'capability' AND g.effect = 'deny' AND g.revoked_at IS NULL
),
granted AS (
    SELECT user_id, capability, 'baseline' AS via FROM baseline
    UNION
    SELECT user_id, capability, 'added' AS via FROM added
)
SELECT s.user_id, c.key AS capability, 'superadmin' AS via
FROM superadmin s CROSS JOIN app.capability c
UNION
SELECT g.user_id, g.capability, min(g.via) AS via
FROM granted g
WHERE g.user_id NOT IN (SELECT user_id FROM superadmin)
  AND NOT EXISTS (
      SELECT 1 FROM denied d
      WHERE d.user_id = g.user_id AND d.capability = g.capability
  )
GROUP BY g.user_id, g.capability;

CREATE OR REPLACE FUNCTION app.holds_capability(who text, want text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM app.capability c
        WHERE c.key = want AND c.every_account
    ) OR EXISTS (
        SELECT 1 FROM app.effective_capability e
        WHERE e.user_id = who AND e.capability = want
    );
$$;

CREATE OR REPLACE FUNCTION app.may_see_channel(who text, channel text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM app.grant g JOIN app.role r ON r.name = g.name
        WHERE g.user_id = who AND g.kind = 'role' AND g.revoked_at IS NULL AND r.everything
    ) OR EXISTS (
        SELECT 1 FROM app.channel_audience a
        WHERE a.channel_id = channel AND a.audience = 'public'
    ) OR (
        app.holds_capability(who, 'channel.read') AND EXISTS (
            SELECT 1 FROM app.channel_grants cg
            WHERE cg.channel_id = channel AND cg.revoked_at IS NULL
              AND (
                  cg.user_id = who
                  OR cg.role IN (
                      SELECT g.name FROM app.grant g
                      WHERE g.user_id = who AND g.kind = 'role' AND g.revoked_at IS NULL
                  )
              )
        )
    );
$$;

DO $$
BEGIN
    EXECUTE 'GRANT SELECT ON app.capability, app.role, app.role_capability TO rails_app';
    EXECUTE 'GRANT SELECT ON app.effective_capability TO rails_app';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON app.grant TO rails_app';
    EXECUTE 'GRANT USAGE ON SEQUENCE app.grant_id_seq TO rails_app';
    EXECUTE 'GRANT SELECT ON app.capability, app.role, app.role_capability TO pipeline_writer';
    EXECUTE 'GRANT SELECT ON app.effective_capability TO pipeline_writer';
    EXECUTE 'GRANT SELECT ON app.grant TO pipeline_writer';
    EXECUTE 'REVOKE INSERT, UPDATE, DELETE ON app.capability FROM rails_app';
    EXECUTE 'REVOKE INSERT, UPDATE, DELETE ON app.role FROM rails_app';
    EXECUTE 'REVOKE INSERT, UPDATE, DELETE ON app.role_capability FROM rails_app';
    EXECUTE 'REVOKE DELETE ON app.grant FROM rails_app';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN
        RAISE NOTICE 'capability tables: could not set role grants (%), single-role deployment', SQLERRM;
END
$$;
