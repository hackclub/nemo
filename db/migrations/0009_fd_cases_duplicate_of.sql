ALTER TABLE fd.cases
    ADD COLUMN duplicate_of bigint REFERENCES fd.cases(id),
    ADD CONSTRAINT cases_duplicate_of_is_other CHECK (
        duplicate_of IS NULL OR duplicate_of <> id
    ),
    ADD CONSTRAINT cases_duplicate_of_needs_resolution CHECK (
        duplicate_of IS NULL OR resolution = 'duplicate'
    );

CREATE INDEX cases_duplicate_of_idx ON fd.cases (duplicate_of)
    WHERE duplicate_of IS NOT NULL;
