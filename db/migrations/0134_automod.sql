CREATE TABLE fd.automod_words (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    word text NOT NULL,
    match_mode text NOT NULL DEFAULT 'word',
    effect text NOT NULL DEFAULT 'flag',
    category_key text,
    note text,
    active boolean NOT NULL DEFAULT true,
    added_by text NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    retired_at timestamptz,
    retired_by text,
    CONSTRAINT automod_words_word_present CHECK (btrim(word) <> ''),
    CONSTRAINT automod_words_match_known
        CHECK (match_mode IN ('word', 'substring', 'regex')),
    CONSTRAINT automod_words_effect_known
        CHECK (effect IN ('flag', 'warn', 'delete')),
    CONSTRAINT automod_words_retired_together
        CHECK ((retired_at IS NULL) = (retired_by IS NULL)),
    CONSTRAINT automod_words_active_is_not_retired
        CHECK (NOT active OR retired_at IS NULL)
);

CREATE UNIQUE INDEX automod_words_one_live
    ON fd.automod_words (lower(btrim(word)), match_mode)
    WHERE active;

CREATE INDEX automod_words_live ON fd.automod_words (added_at DESC) WHERE active;

CREATE TABLE fd.automod_matches (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    word_id bigint REFERENCES fd.automod_words(id) ON DELETE SET NULL,
    word text NOT NULL,
    effect text NOT NULL,
    user_id text NOT NULL,
    channel_id text NOT NULL,
    message_ts text NOT NULL,
    thread_ts text,
    body text,
    permalink text,
    acted boolean NOT NULL DEFAULT false,
    case_id bigint REFERENCES fd.cases(id),
    at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT automod_matches_effect_known CHECK (effect IN ('flag', 'warn', 'delete'))
);

CREATE UNIQUE INDEX automod_matches_one_per_message
    ON fd.automod_matches (channel_id, message_ts, word);

CREATE INDEX automod_matches_recent ON fd.automod_matches (at DESC);
CREATE INDEX automod_matches_by_member ON fd.automod_matches (user_id, at DESC);
CREATE INDEX automod_matches_loose ON fd.automod_matches (at DESC) WHERE case_id IS NULL;
