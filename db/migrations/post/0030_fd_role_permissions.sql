CREATE TABLE fd.role_permissions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role text NOT NULL,
    permission_key text NOT NULL,
    allowed boolean NOT NULL,
    changed_by text NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT role_permissions_role_known CHECK (
        role IN ('firefighter', 'lead', 'community_manager')
    ),
    CONSTRAINT role_permissions_locked_keys CHECK (permission_key <> 'access.grant')
);

CREATE UNIQUE INDEX role_permissions_one_each
    ON fd.role_permissions (role, permission_key);
