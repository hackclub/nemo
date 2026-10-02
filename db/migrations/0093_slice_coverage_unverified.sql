ALTER TABLE ingest.slice_coverage
    DROP CONSTRAINT IF EXISTS slice_coverage_state_check;

ALTER TABLE ingest.slice_coverage
    ADD CONSTRAINT slice_coverage_state_check
    CHECK (state IN ('claimed', 'complete', 'short', 'superseded', 'unavailable', 'unverified'));

UPDATE ingest.slice_coverage
SET    state = 'unverified',
       note = coalesce(note, 'reclassified: the endpoint returned no count to check against')
WHERE  state = 'short' AND expected IS NULL;

UPDATE ingest.slice_coverage
SET    state = 'unverified',
       note = coalesce(note, 'reclassified: member_days has no usable count, nothing verified this slice')
WHERE  state = 'complete' AND source_key = 'member_days';
