CREATE TABLE fd.member_joins (
    user_id text PRIMARY KEY,
    joined_at timestamptz NOT NULL,
    source text NOT NULL DEFAULT 'team_join',
    CONSTRAINT member_joins_source_known CHECK (source IN ('team_join', 'by_hand'))
);

CREATE INDEX member_joins_recent ON fd.member_joins (joined_at DESC);
