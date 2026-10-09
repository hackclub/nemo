ALTER TABLE fd.member_link_v2 ADD COLUMN IF NOT EXISTS label text;

ALTER TABLE fd.member_link_v2
    ADD CONSTRAINT member_link_v2_label_known
    CHECK (label IN ('household', 'classroom', 'staff_test'));
