CREATE TABLE fd.autoresponse_cooldown (
    user_id text PRIMARY KEY,
    sent_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX autoresponse_cooldown_stale ON fd.autoresponse_cooldown (sent_at);
