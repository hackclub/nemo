CREATE INDEX notes_body_fts ON fd.notes
    USING gin (to_tsvector('simple', coalesce(body, '')))
    WHERE deleted_at IS NULL;

CREATE INDEX case_reports_body_fts ON fd.case_reports
    USING gin (to_tsvector('simple', coalesce(body, '')));

CREATE INDEX cases_member_note_fts ON fd.cases
    USING gin (to_tsvector('simple', coalesce(member_note, '')))
    WHERE member_note IS NOT NULL;

CREATE INDEX decisions_words_fts ON fd.decisions
    USING gin (to_tsvector('simple', title || ' ' || statement));

CREATE INDEX decisions_title_trgm ON fd.decisions
    USING gin (lower(title) gin_trgm_ops);
