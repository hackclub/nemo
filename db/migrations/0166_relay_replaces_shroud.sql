ALTER TABLE fd.intake_conversations ALTER COLUMN source_app SET DEFAULT 'relay';

UPDATE fd.intake_conversations SET source_app = 'relay' WHERE source_app = 'shroud';

UPDATE fd.cases SET source_app = 'relay' WHERE source_app = 'shroud';

UPDATE fd.case_reports SET source_app = 'relay' WHERE source_app = 'shroud';

UPDATE fd.thread_messages SET source_app = 'relay' WHERE source_app = 'shroud';

UPDATE fd.cases
SET external_ref = 'relay:' || substring(external_ref from 8)
WHERE external_ref LIKE 'shroud:%';

UPDATE fd.case_reports
SET external_ref = 'relay:' || substring(external_ref from 8)
WHERE external_ref LIKE 'shroud:%';

UPDATE fd.intake_files
SET purged_by = 'relay:reporter declined'
WHERE purged_by = 'shroud:reporter declined';
