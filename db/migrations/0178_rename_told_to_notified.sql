ALTER TABLE fd.member_guard_events
    DROP CONSTRAINT member_guard_events_verb_known;

UPDATE fd.member_guard_events SET verb = 'notified' WHERE verb = 'told';

ALTER TABLE fd.member_guard_events
    ADD CONSTRAINT member_guard_events_verb_known
    CHECK (verb IN ('held', 'released', 'failed', 'deleted', 'kicked',
                    'let_past', 'notified', 'reset', 'deactivated', 'reactivated'));

DROP INDEX IF EXISTS fd.member_guard_events_still_telling;

ALTER TABLE fd.member_guard_events
    DROP COLUMN IF EXISTS told_ts,
    DROP COLUMN IF EXISTS told_until;

ALTER TABLE fd.cases RENAME COLUMN woke_told_at TO woke_notified_at;

ALTER INDEX IF EXISTS fd.cases_woke_untold_idx RENAME TO cases_woke_notice_pending_idx;
