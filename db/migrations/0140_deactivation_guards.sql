ALTER TABLE fd.member_guards
    DROP CONSTRAINT member_guards_kind_known;

ALTER TABLE fd.member_guards
    ADD CONSTRAINT member_guards_kind_known
    CHECK (kind IN ('shush', 'channel_ban', 'deactivation'));

ALTER TABLE fd.member_guard_events
    DROP CONSTRAINT member_guard_events_verb_known;

ALTER TABLE fd.member_guard_events
    ADD CONSTRAINT member_guard_events_verb_known
    CHECK (verb IN ('held', 'released', 'failed', 'deleted', 'kicked',
                    'let_past', 'told', 'reset', 'deactivated', 'reactivated'));

CREATE INDEX member_guards_lifting_carry ON fd.member_guards (updated_at)
    WHERE state = 'lifting' AND carried_by = 'nemo';
