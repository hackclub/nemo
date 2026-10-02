ALTER TABLE fd.intake_shares
    DROP CONSTRAINT intake_shares_message_id_kind_source_channel_id_source_ts_key;

UPDATE fd.intake_shares keep
SET kind = (ARRAY['forward', 'unfurl', 'link'])[folded.rank],
    source_channel_name = coalesce(keep.source_channel_name, folded.source_channel_name),
    source_thread_ts = coalesce(keep.source_thread_ts, folded.source_thread_ts),
    source_author_user_id = coalesce(keep.source_author_user_id, folded.source_author_user_id),
    source_body = coalesce(keep.source_body, folded.source_body),
    permalink = coalesce(keep.permalink, folded.permalink),
    is_reachable = folded.is_reachable
FROM (
    SELECT min(id) AS keeper,
           count(*) AS seats,
           min(array_position(ARRAY['forward', 'unfurl', 'link'], kind)) AS rank,
           max(source_channel_name) AS source_channel_name,
           max(source_thread_ts) AS source_thread_ts,
           max(source_author_user_id) AS source_author_user_id,
           max(source_body) AS source_body,
           max(permalink) AS permalink,
           bool_or(is_reachable) AS is_reachable
    FROM fd.intake_shares
    GROUP BY message_id, source_channel_id, source_ts
) folded
WHERE keep.id = folded.keeper AND folded.seats > 1;

DELETE FROM fd.intake_shares gone
USING (
    SELECT id,
           min(id) OVER (PARTITION BY message_id, source_channel_id, source_ts) AS keeper
    FROM fd.intake_shares
) seated
WHERE gone.id = seated.id AND seated.id <> seated.keeper;

ALTER TABLE fd.intake_shares
    ADD CONSTRAINT intake_shares_one_per_target
    UNIQUE NULLS NOT DISTINCT (message_id, source_channel_id, source_ts);
