ALTER TABLE fd.cases
    ADD COLUMN followed_decision_id bigint REFERENCES fd.decisions(id) ON DELETE RESTRICT;

CREATE INDEX cases_followed_decision_idx ON fd.cases (followed_decision_id)
    WHERE followed_decision_id IS NOT NULL;
