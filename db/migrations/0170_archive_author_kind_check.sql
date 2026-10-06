ALTER TABLE archive.message
    ADD CONSTRAINT message_author_kind_check
    CHECK (author_kind IN ('member', 'bot', 'unknown')) NOT VALID;
