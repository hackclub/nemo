with engagement as (
    select
        channel_id,
        count(*) as messages_tracked,
        sum(coalesce(unique_user_views_count, 0)) as total_views,
        sum(coalesce(unique_user_reactions_count, 0)) as total_reactions,
        sum(coalesce(unique_user_shares_count, 0)) as total_shares,
        sum(coalesce(unique_user_clicks_count, 0)) as total_clicks
    from {{ ref('fct_message_activity') }}
    group by channel_id
)

select
    c.channel_id,
    c.name as channel_name,
    coalesce(e.messages_tracked, 0) as messages_tracked,
    coalesce(e.total_views, 0) as total_views,
    coalesce(e.total_reactions, 0) as total_reactions,
    coalesce(e.total_shares, 0) as total_shares,
    coalesce(e.total_clicks, 0) as total_clicks,
    'v1' as metric_version
from {{ ref('dim_channel') }} c
left join engagement e on e.channel_id = c.channel_id
order by messages_tracked desc
