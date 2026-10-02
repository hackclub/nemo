DELETE FROM ingest.work_item WHERE work_kind = 'first_reply';

DROP VIEW IF EXISTS analytics.fct_member_first_reply;

DROP TABLE IF EXISTS raw.member_first_reply;
