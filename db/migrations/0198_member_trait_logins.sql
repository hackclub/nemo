LOCK TABLE fd.login_event IN SHARE MODE;

SET LOCAL work_mem = '256MB';

INSERT INTO fd.member_trait (user_id, kind, value, first_seen, last_seen, seen)
SELECT user_id, 'ip', host(ip), min(first_at), max(last_at), sum(hits)
FROM fd.login_event
WHERE ip IS NOT NULL
GROUP BY user_id, host(ip)
UNION ALL
SELECT user_id, 'ip_prefix', host(ip_prefix), min(first_at), max(last_at), sum(hits)
FROM fd.login_event
WHERE ip_prefix IS NOT NULL
GROUP BY user_id, host(ip_prefix)
UNION ALL
SELECT user_id, 'ua_id', ua_id::text, min(first_at), max(last_at), sum(hits)
FROM fd.login_event
WHERE ua_id IS NOT NULL
GROUP BY user_id, ua_id
ON CONFLICT (user_id, kind, value) DO NOTHING;

ANALYZE fd.member_trait;

CREATE OR REPLACE FUNCTION fd.login_event_traits()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    grew integer := NEW.hits - CASE WHEN TG_OP = 'UPDATE' THEN OLD.hits ELSE 0 END;
BEGIN
    INSERT INTO fd.member_trait AS held (user_id, kind, value, first_seen, last_seen, seen)
    SELECT NEW.user_id, one.kind, one.value, NEW.first_at, NEW.last_at, grew
    FROM (VALUES ('ip', host(NEW.ip)), ('ip_prefix', host(NEW.ip_prefix)), ('ua_id', NEW.ua_id::text))
         one (kind, value)
    WHERE one.value IS NOT NULL
    ON CONFLICT (user_id, kind, value) DO UPDATE SET
        first_seen = least(held.first_seen, EXCLUDED.first_seen),
        last_seen = greatest(held.last_seen, EXCLUDED.last_seen),
        seen = held.seen + EXCLUDED.seen,
        updated_at = now()
    WHERE (held.first_seen, held.last_seen, held.seen)
          IS DISTINCT FROM (least(held.first_seen, EXCLUDED.first_seen),
                            greatest(held.last_seen, EXCLUDED.last_seen),
                            held.seen + EXCLUDED.seen);
    RETURN NULL;
END
$$;

CREATE TRIGGER login_event_traits_added
    AFTER INSERT ON fd.login_event
    FOR EACH ROW EXECUTE FUNCTION fd.login_event_traits();
CREATE TRIGGER login_event_traits_changed
    AFTER UPDATE ON fd.login_event
    FOR EACH ROW
    WHEN (OLD.hits IS DISTINCT FROM NEW.hits OR OLD.first_at IS DISTINCT FROM NEW.first_at
          OR OLD.last_at IS DISTINCT FROM NEW.last_at)
    EXECUTE FUNCTION fd.login_event_traits();
