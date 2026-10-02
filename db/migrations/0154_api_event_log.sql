CREATE TABLE api.event_log (
    id            bigserial PRIMARY KEY,
    actor_user_id text,
    verb          text NOT NULL,
    subject       text,
    detail        text,
    at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX event_log_at_idx ON api.event_log (at DESC);
