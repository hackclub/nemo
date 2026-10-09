LOCK TABLE fd.member, fd.member_identity IN SHARE MODE;
LOCK TABLE slack.audit_event IN SHARE MODE;

ALTER TABLE fd.member_trait DROP CONSTRAINT member_trait_kind_known;
ALTER TABLE fd.member_trait ADD CONSTRAINT member_trait_kind_known CHECK (kind IN (
    'ip', 'ip_prefix', 'ua_id', 'ja4',
    'email_domain', 'mailbox', 'local_part',
    'full_name', 'display_name', 'handle_stem', 'inviter'
));

CREATE OR REPLACE FUNCTION fd.mailbox_of(email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    WITH cleaned AS (
        SELECT lower(btrim(email, E' \t\n\r\f\v')) AS address
    ),
    parts AS (
        SELECT split_part(regexp_replace(address, '@[^@]*$', ''), '+', 1) AS local,
               regexp_replace(address, '^.*@', '') AS domain
        FROM cleaned
        WHERE position('@' IN address) > 0
    ),
    gmail AS (
        SELECT CASE WHEN domain IN ('gmail.com', 'googlemail.com') THEN replace(local, '.', '') ELSE local END AS local,
               CASE WHEN domain IN ('gmail.com', 'googlemail.com') THEN 'gmail.com' ELSE domain END AS domain
        FROM parts
    )
    SELECT local || '@' || domain FROM gmail WHERE local <> '' AND domain <> ''
$$;

CREATE OR REPLACE FUNCTION fd.identity_traits_of(email text, real_name text)
RETURNS TABLE (kind text, value text)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT one.kind, one.value
    FROM (VALUES
        ('email_domain', CASE WHEN position('@' IN email) > 0 THEN lower(split_part(email, '@', 2)) END),
        ('mailbox', fd.mailbox_of(email)),
        ('local_part', regexp_replace(fd.mailbox_of(email), '@[^@]*$', '')),
        ('full_name', nullif(lower(btrim(real_name)), ''))
    ) one (kind, value)
    WHERE one.value IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION fd.name_traits_of(display_name text, handle text)
RETURNS TABLE (kind text, value text)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT one.kind, one.value
    FROM (VALUES
        ('display_name', nullif(lower(btrim(display_name)), '')),
        ('handle_stem', nullif(regexp_replace(lower(handle), '[^a-z]+$', ''), ''))
    ) one (kind, value)
    WHERE one.value IS NOT NULL
$$;

INSERT INTO fd.member_trait (user_id, kind, value)
SELECT i.user_id, t.kind, t.value
FROM fd.member_identity i
CROSS JOIN LATERAL fd.identity_traits_of(i.email, i.real_name) t
ON CONFLICT (user_id, kind, value) DO NOTHING;

INSERT INTO fd.member_trait (user_id, kind, value)
SELECT m.user_id, t.kind, t.value
FROM fd.member m
CROSS JOIN LATERAL fd.name_traits_of(m.display_name, m.handle) t
ON CONFLICT (user_id, kind, value) DO NOTHING;

INSERT INTO fd.member_trait (user_id, kind, value, first_seen, last_seen, seen)
SELECT actor_id, 'ja4', payload->'details'->>'client_ja4_fingerprint', min(at), max(at), count(*)
FROM slack.audit_event
WHERE action = 'anomaly' AND actor_id IS NOT NULL
  AND payload->'details'->>'client_ja4_fingerprint' IS NOT NULL
GROUP BY 1, 3
ON CONFLICT (user_id, kind, value) DO NOTHING;

INSERT INTO fd.member_trait (user_id, kind, value, first_seen, last_seen, seen)
SELECT entity_id, 'inviter', actor_id, min(at), max(at), count(*)
FROM slack.audit_event
WHERE action = 'user_created' AND actor_id IS NOT NULL AND entity_id IS NOT NULL
  AND actor_id <> entity_id
GROUP BY 1, 3
ON CONFLICT (user_id, kind, value) DO NOTHING;

CREATE OR REPLACE FUNCTION fd.identity_traits_changed()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        DELETE FROM fd.member_trait
        WHERE user_id = OLD.user_id AND kind IN ('email_domain', 'mailbox', 'local_part', 'full_name');
    END IF;
    IF TG_OP <> 'DELETE' THEN
        INSERT INTO fd.member_trait (user_id, kind, value)
        SELECT NEW.user_id, t.kind, t.value FROM fd.identity_traits_of(NEW.email, NEW.real_name) t
        ON CONFLICT (user_id, kind, value) DO NOTHING;
    END IF;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION fd.name_traits_changed()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        DELETE FROM fd.member_trait
        WHERE user_id = OLD.user_id AND kind IN ('display_name', 'handle_stem');
    END IF;
    IF TG_OP <> 'DELETE' THEN
        INSERT INTO fd.member_trait (user_id, kind, value)
        SELECT NEW.user_id, t.kind, t.value FROM fd.name_traits_of(NEW.display_name, NEW.handle) t
        ON CONFLICT (user_id, kind, value) DO NOTHING;
    END IF;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION fd.audit_event_traits()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    owner_id text;
    trait_kind text;
    trait_value text;
BEGIN
    IF NEW.action = 'anomaly' THEN
        owner_id := NEW.actor_id;
        trait_kind := 'ja4';
        trait_value := NEW.payload->'details'->>'client_ja4_fingerprint';
    ELSIF NEW.entity_id IS DISTINCT FROM NEW.actor_id THEN
        owner_id := NEW.entity_id;
        trait_kind := 'inviter';
        trait_value := NEW.actor_id;
    END IF;
    IF owner_id IS NULL OR trait_value IS NULL THEN
        RETURN NULL;
    END IF;
    INSERT INTO fd.member_trait AS held (user_id, kind, value, first_seen, last_seen, seen)
    VALUES (owner_id, trait_kind, trait_value, NEW.at, NEW.at, 1)
    ON CONFLICT (user_id, kind, value) DO UPDATE SET
        first_seen = least(held.first_seen, EXCLUDED.first_seen),
        last_seen = greatest(held.last_seen, EXCLUDED.last_seen),
        seen = held.seen + 1,
        updated_at = now();
    RETURN NULL;
END
$$;

CREATE TRIGGER member_identity_traits_added
    AFTER INSERT ON fd.member_identity
    FOR EACH ROW EXECUTE FUNCTION fd.identity_traits_changed();
CREATE TRIGGER member_identity_traits_changed
    AFTER UPDATE OF email, real_name ON fd.member_identity
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email OR OLD.real_name IS DISTINCT FROM NEW.real_name)
    EXECUTE FUNCTION fd.identity_traits_changed();
CREATE TRIGGER member_identity_traits_removed
    AFTER DELETE ON fd.member_identity
    FOR EACH ROW EXECUTE FUNCTION fd.identity_traits_changed();

CREATE TRIGGER member_name_traits_added
    AFTER INSERT ON fd.member
    FOR EACH ROW EXECUTE FUNCTION fd.name_traits_changed();
CREATE TRIGGER member_name_traits_changed
    AFTER UPDATE OF display_name, handle ON fd.member
    FOR EACH ROW
    WHEN (OLD.display_name IS DISTINCT FROM NEW.display_name OR OLD.handle IS DISTINCT FROM NEW.handle)
    EXECUTE FUNCTION fd.name_traits_changed();
CREATE TRIGGER member_name_traits_removed
    AFTER DELETE ON fd.member
    FOR EACH ROW EXECUTE FUNCTION fd.name_traits_changed();

CREATE TRIGGER audit_event_traits
    AFTER INSERT ON slack.audit_event
    FOR EACH ROW
    WHEN (NEW.action IN ('anomaly', 'user_created'))
    EXECUTE FUNCTION fd.audit_event_traits();
