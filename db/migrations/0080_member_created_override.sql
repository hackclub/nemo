CREATE TABLE IF NOT EXISTS raw.member_created_override (
    user_id text PRIMARY KEY,
    account_created_verified timestamptz NOT NULL,
    source text NOT NULL DEFAULT 'slack_admin_csv_export',
    imported_at timestamptz NOT NULL DEFAULT now()
);
