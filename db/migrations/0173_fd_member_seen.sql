CREATE TABLE IF NOT EXISTS fd.member_seen (
    user_id       text PRIMARY KEY,
    last_post_at  timestamptz,
    last_login_at timestamptz
);

INSERT INTO fd.member_seen (user_id, last_login_at)
SELECT user_id, max(at)
FROM fd.login_event
WHERE action IN ('access_log', 'user_login')
GROUP BY user_id
ON CONFLICT (user_id) DO UPDATE SET last_login_at = EXCLUDED.last_login_at
WHERE fd.member_seen.last_login_at IS NULL OR fd.member_seen.last_login_at < EXCLUDED.last_login_at;

DO $$
BEGIN
    IF to_regclass('analytics.fct_member_lifetime_messages') IS NOT NULL THEN
        INSERT INTO fd.member_seen (user_id, last_post_at)
        SELECT user_id, last_at
        FROM analytics.fct_member_lifetime_messages
        WHERE last_at IS NOT NULL
        ON CONFLICT (user_id) DO UPDATE SET last_post_at = EXCLUDED.last_post_at
        WHERE fd.member_seen.last_post_at IS NULL OR fd.member_seen.last_post_at < EXCLUDED.last_post_at;
    END IF;
END $$;
