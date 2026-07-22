select
    channel_id,
    message_ts,
    source,
    unique_user_views_count,
    unique_user_reactions_count,
    unique_user_shares_count,
    unique_user_clicks_count,
    views_client,
    stats_by_department,
    stats_by_org,
    pulled_at
from {{ source('raw', 'message_activity_snapshot') }}
