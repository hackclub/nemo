ALTER TABLE fd.actions
    ADD COLUMN cites_message_id bigint
        REFERENCES fd.thread_messages(id) ON DELETE RESTRICT;

CREATE INDEX actions_cited_message_idx
    ON fd.actions (cites_message_id)
    WHERE cites_message_id IS NOT NULL;
