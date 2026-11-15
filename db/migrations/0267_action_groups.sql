ALTER TABLE fd.actions ADD COLUMN group_id bigint REFERENCES fd.actions(id);

CREATE INDEX actions_group_idx ON fd.actions (group_id) WHERE group_id IS NOT NULL;

WITH imported AS (
    SELECT id,
           min(id) OVER (PARTITION BY split_part(external_ref, ':', 3)) AS first_id,
           count(*) OVER (PARTITION BY split_part(external_ref, ':', 3)) AS types
    FROM fd.actions
    WHERE external_ref LIKE 'lyla:action:%:%'
)
UPDATE fd.actions a
SET group_id = imported.first_id
FROM imported
WHERE a.id = imported.id AND imported.types > 1;
