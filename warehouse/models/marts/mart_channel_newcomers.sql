{% set window_days = 90 %}

{{ config(indexes=[{'columns': ['channel_id'], 'unique': True}]) }}

with edge as (
    select max(ds) as last_day
    from {{ ref('mart_channel_day') }}
),

span as (
    select
        (last_day - {{ window_days - 1 }})::date as window_start,
        last_day as window_end
    from edge
),

walked as (
    select channel_id
    from {{ ref('fct_channel_walk') }}
    where coalesce(history_complete, false)
),

landed as (
    select
        f.channel_id,
        f.user_id
    from {{ ref('fct_message_first_post') }} f
    inner join walked w on w.channel_id = f.channel_id
    inner join {{ ref('dim_member') }} d on d.user_id = f.user_id
    cross join span s
    where not d.is_bot
      and not d.is_deleted
      and (f.posted_at at time zone 'UTC')::date between s.window_start and s.window_end
),

shaped as (
    select
        l.channel_id,
        coalesce(r.answered, false) as answered,
        r.answered and r.latency_seconds < {{ var('fast_reply_seconds') }} as fast,
        coalesce(r.bot_replied, false) as bot_replied,
        case when r.answered then r.latency_seconds end as latency_seconds,
        coalesce(m.day_30_covered, false) as day_30_covered,
        coalesce(m.retained_day_30, false) as retained_day_30
    from landed l
    inner join {{ ref('fct_first_response') }} r on r.newcomer_id = l.user_id
    left join {{ ref('fct_member_retention') }} m on m.user_id = l.user_id
)

select
    s.channel_id,
    c.name as channel_name,
    count(*)::integer as newcomers,
    count(*) filter (where s.answered)::integer as answered_by_member,
    count(*) filter (where s.fast)::integer as answered_fast,
    count(*) filter (where not s.answered and s.bot_replied)::integer as answered_by_bot,
    count(*) filter (where not s.answered and not s.bot_replied)::integer as unanswered,
    count(*) filter (where s.day_30_covered)::integer as measured_day_30,
    count(*) filter (where s.day_30_covered and s.retained_day_30)::integer as returned_day_30,
    round(count(*) filter (where s.answered)::numeric / nullif(count(*), 0), 4) as answered_share,
    round(count(*) filter (where s.fast)::numeric / nullif(count(*), 0), 4) as fast_share,
    round(count(*) filter (where s.day_30_covered and s.retained_day_30)::numeric
        / nullif(count(*) filter (where s.day_30_covered), 0), 4) as returned_share,
    percentile_cont(0.5) within group (order by s.latency_seconds)::integer
        as median_latency_seconds,
    {{ var('fast_reply_seconds') }}::integer as fast_reply_seconds,
    w.window_start,
    w.window_end,
    'v2' as metric_version
from shaped s
left join {{ ref('dim_channel') }} c on c.channel_id = s.channel_id
cross join span w
group by s.channel_id, c.name, w.window_start, w.window_end
