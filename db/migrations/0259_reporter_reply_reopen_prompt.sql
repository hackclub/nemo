ALTER TABLE fd.cases RENAME COLUMN woke_at TO reporter_replied_at;

ALTER TABLE fd.cases RENAME COLUMN woke_notified_at TO reopen_prompt_posted_at;

ALTER TABLE fd.cases DROP COLUMN IF EXISTS woke_from;

ALTER INDEX IF EXISTS fd.cases_woke_notice_pending_idx RENAME TO cases_reopen_prompt_pending_idx;
