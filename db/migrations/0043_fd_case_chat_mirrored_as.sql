ALTER TABLE fd.case_chat ADD COLUMN mirrored_as text;

ALTER TABLE fd.case_chat ADD CONSTRAINT case_chat_carried_by_somebody
    CHECK (mirrored_as IS NULL OR mirrored_as IN ('user', 'nemo'));

CREATE INDEX case_chat_unclaimed_idx
    ON fd.case_chat (case_id, said_at)
    WHERE ts IS NULL AND mirrored_ts IS NULL AND mirrored_as IS NULL;
