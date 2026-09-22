CREATE TABLE fd.channel_membership (
    channel_id text PRIMARY KEY,
    inside boolean NOT NULL,
    at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX channel_membership_seated ON fd.channel_membership (channel_id)
    WHERE inside;
