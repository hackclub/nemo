CREATE OR REPLACE FUNCTION fd.automod_word_changed() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_automod_word', COALESCE(NEW.id, OLD.id)::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER automod_words_changed
    AFTER INSERT OR UPDATE OF active, word, match_mode, effect, category_key OR DELETE
    ON fd.automod_words
    FOR EACH ROW EXECUTE FUNCTION fd.automod_word_changed();
