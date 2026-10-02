UPDATE fd.case_participants SET role = 'subject' WHERE role = 'involved';

ALTER TABLE fd.case_participants
    DROP CONSTRAINT case_participants_role_check;

ALTER TABLE fd.case_participants
    ADD CONSTRAINT case_participants_role_check
    CHECK (role IN ('subject', 'reporter'));

ALTER TABLE fd.case_participants DROP COLUMN detail;
