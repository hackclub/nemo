UPDATE ingest.slice_coverage
SET    state = 'unverified',
       note = coalesce(note, 'reclassified: member_days has no usable count, nothing verified this slice')
WHERE  state = 'short' AND source_key = 'member_days';
