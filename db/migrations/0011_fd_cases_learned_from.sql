ALTER TABLE fd.cases
    ADD COLUMN learned_from text,
    ADD CONSTRAINT cases_learned_from_check CHECK (
        learned_from IS NULL OR learned_from IN ('saw_it', 'told_in_dm', 'off_slack', 'staff')
    );
