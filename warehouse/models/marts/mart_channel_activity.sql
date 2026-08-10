{{ config(indexes=[{'columns': ['channel_id', 'window_start']}]) }}

select
    channel_id,
    window_start,
    window_end,
    messages_posted,
    messages_posted_by_members,
    members_who_posted,
    members_who_viewed,
    reactions_added,
    huddles_initiated,
    'v2' as metric_version
from {{ ref('fct_channel_activity') }}
