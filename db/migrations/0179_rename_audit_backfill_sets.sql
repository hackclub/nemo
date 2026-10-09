UPDATE ingest.slice_coverage
SET source_key = 'audit_logs_backfill:login_and_channel'
WHERE source_key = 'audit_logs_backfill:watched';

UPDATE ingest.slice_coverage
SET source_key = 'audit_logs_backfill:login'
WHERE source_key = 'audit_logs_backfill:logins';

UPDATE ingest.slice_coverage
SET source_key = 'audit_logs_backfill:channel_membership'
WHERE source_key = 'audit_logs_backfill:channels';

UPDATE ingest.slice_coverage
SET source_key = 'audit_logs_backfill:custom'
WHERE source_key = 'audit_logs_backfill:picked';
