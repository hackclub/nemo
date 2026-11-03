CREATE INDEX IF NOT EXISTS login_event_updated_prefix_idx ON fd.login_event (updated_at, ip_prefix)
    WHERE ip_prefix IS NOT NULL;

CREATE INDEX IF NOT EXISTS ip_network_default_idx ON fd.ip_network (classified_at)
    WHERE source = 'default';
