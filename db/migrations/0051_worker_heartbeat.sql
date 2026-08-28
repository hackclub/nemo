CREATE TABLE raw.worker_heartbeat (
    worker text PRIMARY KEY,
    beat_at timestamptz NOT NULL DEFAULT now(),
    note text,
    created_at timestamptz NOT NULL DEFAULT now()
);
