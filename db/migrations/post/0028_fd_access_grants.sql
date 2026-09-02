CREATE TABLE fd.access_grants (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id text NOT NULL,
    role text NOT NULL,
    reason text,
    granted_by text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_by text,
    revoked_at timestamptz,
    CONSTRAINT access_grants_role_known CHECK (
        role IN ('firefighter', 'lead', 'community_manager')
    ),
    CONSTRAINT access_grants_revoked_together CHECK (
        (revoked_at IS NULL) = (revoked_by IS NULL)
    ),
    CONSTRAINT access_grants_reason_present CHECK (reason IS NULL OR btrim(reason) <> ''),
    CONSTRAINT access_grants_revoked_after_granted CHECK (
        revoked_at IS NULL OR revoked_at >= granted_at
    )
);

CREATE UNIQUE INDEX access_grants_one_live ON fd.access_grants (user_id)
    WHERE revoked_at IS NULL;

CREATE INDEX access_grants_person_idx ON fd.access_grants (user_id, granted_at DESC);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'app' AND table_name = 'staff'
    ) THEN
        EXECUTE $sql$
            INSERT INTO fd.access_grants (user_id, role, reason, granted_by)
            SELECT user_id, 'community_manager', 'held the community manager flag', 'backfill'
            FROM app.staff
            WHERE community_manager
        $sql$;
    END IF;
END
$$;
