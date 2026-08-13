ALTER TABLE fd.case_participants
    DROP CONSTRAINT case_participants_role_check;

ALTER TABLE fd.case_participants
    ADD COLUMN detail text;

UPDATE fd.case_participants
SET role = 'involved',
    detail = CASE role
        WHEN 'target' THEN 'it was aimed at them'
        ELSE 'took part in the thread'
    END
WHERE role IN ('target', 'witness', 'participant');

ALTER TABLE fd.case_participants
    ADD CONSTRAINT case_participants_role_check
    CHECK (role IN ('subject', 'reporter', 'involved'));

ALTER TABLE fd.case_participants
    ADD CONSTRAINT case_participants_involved_has_detail
    CHECK (role <> 'involved' OR detail IS NOT NULL);
