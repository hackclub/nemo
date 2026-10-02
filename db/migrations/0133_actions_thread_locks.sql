ALTER TABLE fd.actions ALTER COLUMN target_user_id DROP NOT NULL;

ALTER TABLE fd.actions
    ADD COLUMN thread_guard_id bigint REFERENCES fd.thread_guards(id) ON DELETE SET NULL;

ALTER TABLE fd.actions
    ADD CONSTRAINT actions_target_or_thread
    CHECK (target_user_id IS NOT NULL OR type_key = 'locked_thread');

ALTER TABLE fd.actions
    ADD CONSTRAINT actions_thread_guard_is_a_lock
    CHECK (thread_guard_id IS NULL OR type_key = 'locked_thread');

CREATE INDEX actions_thread_guard_idx ON fd.actions (thread_guard_id)
    WHERE thread_guard_id IS NOT NULL;

COMMENT ON COLUMN fd.actions.target_user_id IS
    'Who the action was directed at. Null for a locked thread, which is held against the case and the thread, not a member.';

COMMENT ON COLUMN fd.actions.thread_guard_id IS
    'The thread lock this action records. The bot opens the lock from Slack; logging it here is what puts it on the case record.';
