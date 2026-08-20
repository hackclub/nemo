ALTER TABLE fd.case_reports
    ADD COLUMN card_digest text,
    ADD COLUMN card_rendered_at timestamptz;

CREATE INDEX case_reports_uncarded_idx
    ON fd.case_reports (id)
    WHERE forwarded_ts IS NULL;
