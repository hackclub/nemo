CREATE TABLE fd.case_chat (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id bigint NOT NULL REFERENCES fd.cases(id) ON DELETE RESTRICT,
    author_user_id text NOT NULL,
    body text,
    blocks jsonb,
    said_at timestamptz NOT NULL DEFAULT now(),
    channel_id text,
    ts text,
    thread_ts text,
    edited_at timestamptz,
    deleted_at timestamptz,
    mirrored_ts text,
    mirrored_at timestamptz,
    source_app text NOT NULL DEFAULT 'nemo',
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT case_chat_slack_pair CHECK ((channel_id IS NULL) = (ts IS NULL)),
    CONSTRAINT case_chat_has_words CHECK (body IS NOT NULL OR blocks IS NOT NULL),
    CONSTRAINT case_chat_mirrored_together CHECK ((mirrored_ts IS NULL) = (mirrored_at IS NULL)),
    CONSTRAINT case_chat_came_from_somewhere CHECK (ts IS NOT NULL OR source_app <> 'nemo')
);

CREATE UNIQUE INDEX case_chat_slack_idx
    ON fd.case_chat (channel_id, ts)
    WHERE ts IS NOT NULL;

CREATE INDEX case_chat_case_idx
    ON fd.case_chat (case_id, said_at);

CREATE INDEX case_chat_unmirrored_idx
    ON fd.case_chat (case_id, said_at)
    WHERE ts IS NULL AND mirrored_ts IS NULL;

CREATE OR REPLACE FUNCTION fd.chat_changed() RETURNS trigger AS $$
DECLARE
    touched bigint;
BEGIN
    IF TG_OP = 'DELETE' THEN
        touched := OLD.case_id;
    ELSE
        touched := NEW.case_id;
    END IF;

    IF touched IS NOT NULL THEN
        PERFORM pg_notify('fd_chat_changed', touched::text);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER case_chat_changed
    AFTER INSERT OR UPDATE OR DELETE ON fd.case_chat
    FOR EACH ROW EXECUTE FUNCTION fd.chat_changed();
