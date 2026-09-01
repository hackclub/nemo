CREATE SCHEMA IF NOT EXISTS ingest;

CREATE TABLE IF NOT EXISTS ingest.source_object (
    source_object_id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    system text NOT NULL DEFAULT 'slack',
    object_name text NOT NULL,
    endpoint text NOT NULL,
    credential_class text NOT NULL,
    documented boolean NOT NULL DEFAULT true,
    sensitivity text NOT NULL DEFAULT 'metadata',
    expected_grain text,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (system, object_name)
);

CREATE TABLE IF NOT EXISTS ingest.sync_recipe (
    recipe_key text PRIMARY KEY,
    source_object_id smallint NOT NULL REFERENCES ingest.source_object,
    sync_mode text NOT NULL,
    window_strategy text,
    cursor_type text,
    schedule text,
    params jsonb NOT NULL DEFAULT '{}'::jsonb,
    parser_version smallint NOT NULL DEFAULT 1,
    manifest_hash text,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ingest.sync_run (
    run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    logical_date date NOT NULL,
    trigger text NOT NULL,
    code_sha text,
    manifest_hash text,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running',
    error_summary text,
    legacy_run_id bigint
);

CREATE INDEX IF NOT EXISTS sync_run_logical_date_idx ON ingest.sync_run (logical_date DESC);

CREATE TABLE IF NOT EXISTS ingest.sync_task (
    task_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id bigint REFERENCES ingest.sync_run,
    recipe_key text NOT NULL,
    stream_key text NOT NULL DEFAULT '',
    slice_start date,
    slice_end date,
    idempotency_key text NOT NULL,
    attempt smallint NOT NULL DEFAULT 1,
    cursor_in text,
    cursor_out text,
    status text NOT NULL DEFAULT 'running',
    rows_in integer NOT NULL DEFAULT 0,
    rows_rejected integer NOT NULL DEFAULT 0,
    pages integer NOT NULL DEFAULT 0,
    rate_limited_seconds integer NOT NULL DEFAULT 0,
    error_class text,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    UNIQUE (idempotency_key, attempt)
);

CREATE INDEX IF NOT EXISTS sync_task_run_idx ON ingest.sync_task (run_id);
CREATE INDEX IF NOT EXISTS sync_task_recipe_idx ON ingest.sync_task (recipe_key, started_at DESC);

CREATE TABLE IF NOT EXISTS ingest.cursor_state (
    recipe_key text NOT NULL,
    stream_key text NOT NULL DEFAULT '',
    cursor text,
    cursor_version smallint NOT NULL DEFAULT 1,
    high_watermark timestamptz,
    rows_seen bigint NOT NULL DEFAULT 0,
    last_task_id bigint,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (recipe_key, stream_key)
);

CREATE TABLE IF NOT EXISTS ingest.coverage (
    recipe_key text NOT NULL,
    stream_key text NOT NULL DEFAULT '',
    slice_start date NOT NULL,
    slice_end date NOT NULL,
    status text NOT NULL,
    expected_count bigint,
    landed_count bigint,
    drift numeric,
    reason text,
    verified_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (recipe_key, stream_key, slice_start, slice_end)
);

CREATE INDEX IF NOT EXISTS coverage_status_idx ON ingest.coverage (status, slice_start DESC);

CREATE TABLE IF NOT EXISTS ingest.work_item (
    work_item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    work_kind text NOT NULL,
    target_key text NOT NULL,
    target_sub_key text NOT NULL DEFAULT '',
    state text NOT NULL DEFAULT 'pending',
    priority integer NOT NULL DEFAULT 100,
    expected integer,
    fetched integer NOT NULL DEFAULT 0,
    attempts smallint NOT NULL DEFAULT 0,
    next_attempt_at timestamptz,
    claimed_by text,
    claimed_at timestamptz,
    lease_expires_at timestamptz,
    last_error text,
    requested_by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (work_kind, target_key, target_sub_key)
);

CREATE INDEX IF NOT EXISTS work_item_ready_idx
    ON ingest.work_item (work_kind, state, priority, created_at)
    WHERE state = 'pending';

CREATE TABLE IF NOT EXISTS ingest.throttle_state (
    app_name text NOT NULL,
    method text NOT NULL,
    observed_limit_per_min integer,
    tokens_remaining integer,
    consecutive_429 integer NOT NULL DEFAULT 0,
    last_429_at timestamptz,
    retry_after_seconds integer,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (app_name, method)
);

CREATE TABLE IF NOT EXISTS ingest.schema_drift (
    source_object_id smallint NOT NULL REFERENCES ingest.source_object,
    json_path text NOT NULL,
    json_type text NOT NULL,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    times_seen bigint NOT NULL DEFAULT 1,
    approved boolean NOT NULL DEFAULT false,
    PRIMARY KEY (source_object_id, json_path, json_type)
);

CREATE TABLE IF NOT EXISTS ingest.quality_result (
    quality_result_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id bigint REFERENCES ingest.sync_run,
    subject text NOT NULL,
    assertion text NOT NULL,
    severity text NOT NULL DEFAULT 'warn',
    status text NOT NULL,
    observed text,
    expected text,
    checked_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS quality_result_run_idx ON ingest.quality_result (run_id);
