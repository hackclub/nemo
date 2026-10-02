ALTER TABLE fd.channel_guards
    DROP CONSTRAINT channel_guards_reason_present;

ALTER TABLE fd.channel_guards
    ALTER COLUMN reason DROP NOT NULL;
