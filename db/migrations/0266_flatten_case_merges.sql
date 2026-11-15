WITH RECURSIVE chain(id, root_id, depth) AS (
    SELECT id, id, 0 FROM fd.cases WHERE duplicate_of IS NULL
    UNION ALL
    SELECT c.id, chain.root_id, chain.depth + 1
    FROM fd.cases c JOIN chain ON c.duplicate_of = chain.id
    WHERE chain.depth < 50
)
UPDATE fd.cases c
SET duplicate_of = chain.root_id, updated_at = now()
FROM chain
WHERE c.id = chain.id AND chain.depth > 1;

DELETE FROM fd.case_tags t
USING fd.case_merges m
WHERE t.merge_id = m.id AND m.unmerged_at IS NOT NULL;
