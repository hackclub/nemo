ALTER TABLE fd.case_reports
    ADD COLUMN closed_by text;

ALTER TABLE fd.case_reports
    ADD CONSTRAINT case_reports_closed_together CHECK (
        (closed_at IS NULL) = (closed_by IS NULL)
    ) NOT VALID;
