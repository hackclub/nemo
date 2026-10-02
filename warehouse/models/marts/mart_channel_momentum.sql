{% set window_days = 28 %}
{% set prior_floor = 500 %}

with edge as (
    select max(window_start) as last_day
    from {{ ref('mart_channel_activity') }}
),

spans as (
    select
        last_day - {{ window_days - 1 }} as window_start,
        last_day as window_end,
        last_day - {{ window_days * 2 - 1 }} as prior_start,
        last_day - {{ window_days }} as prior_end
    from edge
),

paired as (
    select
        a.channel_id,
        sum(a.messages_posted_by_members) filter (
            where a.window_start between s.window_start and s.window_end
        ) as messages,
        sum(a.messages_posted_by_members) filter (
            where a.window_start between s.prior_start and s.prior_end
        ) as prior_messages
    from {{ ref('mart_channel_activity') }} a
    cross join spans s
    where a.window_start between s.prior_start and s.window_end
    group by a.channel_id
),

live as (
    select
        p.channel_id,
        c.name,
        coalesce(p.messages, 0) as messages,
        coalesce(p.prior_messages, 0) as prior_messages
    from paired p
    join {{ ref('dim_channel') }} c on c.channel_id = p.channel_id
    where not coalesce(c.archived, false)
      and coalesce(p.messages, 0) > 0
),

scaled as (
    select
        channel_id,
        name,
        messages,
        prior_messages,
        prior_messages < {{ prior_floor }} as prior_below_floor,
        case
            when prior_messages >= {{ prior_floor }}
            then round(100.0 * (messages - prior_messages) / prior_messages, 1)
        end as pct_change,
        round(100.0 * messages / nullif(sum(messages) over (), 0), 4) as share_of_total,
        row_number() over (order by messages desc, channel_id) as rank,
        sum(messages) over ()::bigint as total_messages,
        count(*) over () as active_channels
    from live
)

select
    s.channel_id,
    s.name,
    s.messages,
    s.prior_messages,
    s.prior_below_floor,
    s.pct_change,
    s.share_of_total,
    s.rank::integer as rank,
    s.total_messages,
    s.active_channels::integer as active_channels,
    {{ prior_floor }}::integer as prior_floor,
    p.window_start,
    p.window_end,
    p.prior_start,
    p.prior_end,
    'v1' as metric_version
from scaled s
cross join spans p
order by s.rank
