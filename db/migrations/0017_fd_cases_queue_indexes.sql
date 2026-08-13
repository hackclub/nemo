CREATE INDEX cases_opened_at_idx ON fd.cases (opened_at DESC);

CREATE INDEX cases_category_idx ON fd.cases (category_key)
    WHERE category_key IS NOT NULL;

CREATE INDEX cases_resolved_idx ON fd.cases (resolved_at DESC)
    WHERE resolved_at IS NOT NULL;
