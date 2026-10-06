ALTER TABLE fd.member_guards RENAME COLUMN carry TO enforcement_status;
ALTER TABLE fd.member_guards RENAME COLUMN carried_by TO enforced_by;

ALTER TABLE fd.member_guards
    RENAME CONSTRAINT member_guards_carry_known TO member_guards_enforcement_status_known;
ALTER TABLE fd.member_guards
    RENAME CONSTRAINT member_guards_carried_by_known TO member_guards_enforced_by_known;

ALTER INDEX fd.member_guards_lifting_carry RENAME TO member_guards_lifting_enforced;
