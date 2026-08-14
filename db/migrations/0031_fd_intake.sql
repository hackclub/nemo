CREATE TABLE fd.intake_conversations (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id text NOT NULL,
    member_user_id text REFERENCES fd.member(user_id) ON DELETE SET NULL,
    report_id bigint REFERENCES fd.case_reports(id) ON DELETE SET NULL,
    opened_at timestamptz NOT NULL DEFAULT now(),
    handed_off_at timestamptz,
    last_message_at timestamptz,
    closed_at timestamptz,
    closed_by text,
    purged_at timestamptz,
    purged_by text,
    source_app text NOT NULL DEFAULT 'shroud',
    CONSTRAINT intake_conversations_closed_together CHECK ((closed_at IS NULL) = (closed_by IS NULL)),
    CONSTRAINT intake_conversations_purged_together CHECK ((purged_at IS NULL) = (purged_by IS NULL)),
    CONSTRAINT intake_conversations_purged_has_no_member CHECK (purged_at IS NULL OR member_user_id IS NULL),
    CONSTRAINT intake_conversations_handed_off_has_report CHECK (handed_off_at IS NULL OR report_id IS NOT NULL)
);

CREATE UNIQUE INDEX intake_conversations_one_open
    ON fd.intake_conversations (channel_id)
    WHERE closed_at IS NULL;

CREATE INDEX intake_conversations_member_idx
    ON fd.intake_conversations (member_user_id, opened_at DESC)
    WHERE member_user_id IS NOT NULL;

CREATE UNIQUE INDEX intake_conversations_report_idx
    ON fd.intake_conversations (report_id)
    WHERE report_id IS NOT NULL;

CREATE INDEX intake_conversations_waiting_idx
    ON fd.intake_conversations (last_message_at)
    WHERE closed_at IS NULL;

CREATE TABLE fd.intake_messages (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id bigint NOT NULL REFERENCES fd.intake_conversations(id) ON DELETE CASCADE,
    channel_id text NOT NULL,
    ts text NOT NULL,
    thread_ts text,
    client_msg_id text,
    direction text NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    author_user_id text,
    author_bot_id text,
    sent_by text,
    subtype text,
    body text,
    blocks jsonb,
    attachments jsonb,
    raw jsonb,
    revision integer NOT NULL DEFAULT 0,
    posted_at timestamptz NOT NULL,
    edited_at timestamptz,
    edited_by text,
    deleted_at timestamptz,
    mirrored_ts text,
    mirrored_at timestamptz,
    purged_at timestamptz,
    purged_by text,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (channel_id, ts),
    CONSTRAINT intake_messages_inbound_is_not_sent CHECK (direction = 'outbound' OR sent_by IS NULL),
    CONSTRAINT intake_messages_written_by_somebody CHECK (
        direction = 'outbound'
        OR author_user_id IS NOT NULL
        OR author_bot_id IS NOT NULL
        OR subtype IS NOT NULL
    ),
    CONSTRAINT intake_messages_mirrored_together CHECK ((mirrored_at IS NULL) = (mirrored_ts IS NULL)),
    CONSTRAINT intake_messages_purged_together CHECK ((purged_at IS NULL) = (purged_by IS NULL)),
    CONSTRAINT intake_messages_purged_has_no_body CHECK (
        purged_at IS NULL OR (body IS NULL AND blocks IS NULL AND attachments IS NULL AND raw IS NULL)
    )
);

CREATE INDEX intake_messages_conversation_idx
    ON fd.intake_messages (conversation_id, posted_at);

CREATE INDEX intake_messages_thread_idx
    ON fd.intake_messages (channel_id, thread_ts, posted_at)
    WHERE thread_ts IS NOT NULL;

CREATE UNIQUE INDEX intake_messages_mirror_idx
    ON fd.intake_messages (mirrored_ts)
    WHERE mirrored_ts IS NOT NULL;

CREATE TABLE fd.intake_revisions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    message_id bigint NOT NULL REFERENCES fd.intake_messages(id) ON DELETE CASCADE,
    seq integer NOT NULL,
    body text,
    blocks jsonb,
    attachments jsonb,
    digest text NOT NULL,
    edited_at timestamptz,
    edited_by text,
    observed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (message_id, seq),
    CONSTRAINT intake_revisions_seq_is_not_negative CHECK (seq >= 0),
    CONSTRAINT intake_revisions_first_is_unedited CHECK (seq > 0 OR edited_at IS NULL)
);

CREATE TABLE fd.intake_shares (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    message_id bigint NOT NULL REFERENCES fd.intake_messages(id) ON DELETE CASCADE,
    kind text NOT NULL CHECK (kind IN ('forward', 'unfurl', 'link')),
    source_channel_id text,
    source_channel_name text,
    source_ts text,
    source_thread_ts text,
    source_author_user_id text,
    source_body text,
    permalink text,
    is_reachable boolean NOT NULL DEFAULT false,
    raw jsonb,
    observed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (message_id, kind, source_channel_id, source_ts),
    CONSTRAINT intake_shares_points_somewhere CHECK (
        permalink IS NOT NULL OR (source_channel_id IS NOT NULL AND source_ts IS NOT NULL)
    )
);

CREATE INDEX intake_shares_source_idx
    ON fd.intake_shares (source_channel_id, source_ts)
    WHERE source_channel_id IS NOT NULL AND source_ts IS NOT NULL;

DO $$
DECLARE
    name text;
BEGIN
    FOREACH name IN ARRAY ARRAY[
        'fd.intake_conversations',
        'fd.intake_messages',
        'fd.intake_revisions',
        'fd.intake_shares'
    ]
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
            EXECUTE format('REVOKE ALL ON %s FROM dbt_owner', name);
        END IF;

        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
            EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %s FROM rails_app', name);
        END IF;
    END LOOP;
END
$$;
