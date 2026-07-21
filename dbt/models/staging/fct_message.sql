select
    payload->>'user' as user_id,
    payload->>'channel' as channel_id,
    payload->>'ts' as ts,
    payload->>'thread_ts' as thread_ts,
    to_timestamp((payload->>'ts')::double precision) as posted_at
from {{ source('raw', 'slack_events') }}
where event_type = 'message'
