ALTER TABLE fd.actions
    ADD COLUMN reason text,
    ADD COLUMN category_key text;

UPDATE fd.actions a
SET category_key = c.category_key
FROM fd.cases c
WHERE c.id = a.case_id
  AND c.category_key IS NOT NULL;

CREATE INDEX actions_category_idx ON fd.actions (category_key)
    WHERE category_key IS NOT NULL;
