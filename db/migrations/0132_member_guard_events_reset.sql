ALTER TABLE fd.member_guard_events
    DROP CONSTRAINT member_guard_events_verb_known;

ALTER TABLE fd.member_guard_events
    ADD CONSTRAINT member_guard_events_verb_known
    CHECK (verb IN ('held', 'released', 'failed', 'deleted', 'kicked',
                    'let_past', 'told', 'reset'));

CREATE INDEX member_guard_events_lately
    ON fd.member_guard_events (guard_id, verb, at DESC);
