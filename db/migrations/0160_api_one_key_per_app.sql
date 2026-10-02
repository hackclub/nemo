UPDATE api.setting SET value = 1, changed_at = now()
WHERE key = 'tokens_per_owner' AND value = 3;
