with reply_speed as (
    select
        r.newcomer_id,
        case
            when not r.answered then 'none'
            when r.latency_seconds < 3600 and not r.replied_by_bot then 'fast'
            else 'slow'
        end as reply_class
    from {{ ref('fct_first_reply') }} r
    inner join {{ ref('dim_member') }} d on d.user_id = r.newcomer_id
    where not d.is_bot
),

scoped as (
    select
        rs.reply_class,
        m.retained_day_30,
        m.retained_day_90,
        m.day_30_covered,
        m.day_90_covered
    from reply_speed rs
    inner join {{ ref('fct_member_retention') }} m on m.user_id = rs.newcomer_id
),

covered as (
    select
        min(post_at)::date as window_start,
        max(post_at)::date as window_end
    from {{ ref('fct_first_reply') }}
)

select
    reply_class,
    count(*) as newcomers,
    count(*) filter (where day_30_covered) as measured_day_30,
    count(*) filter (where day_30_covered and retained_day_30) as retained_day_30_count,
    round(
        count(*) filter (where day_30_covered and retained_day_30)::numeric
            / nullif(count(*) filter (where day_30_covered), 0),
        4
    ) as retained_day_30_rate,
    count(*) filter (where day_90_covered) as measured_day_90,
    count(*) filter (where day_90_covered and retained_day_90) as retained_day_90_count,
    round(
        count(*) filter (where day_90_covered and retained_day_90)::numeric
            / nullif(count(*) filter (where day_90_covered), 0),
        4
    ) as retained_day_90_rate,
    c.window_start,
    c.window_end,
    'v7' as metric_version
from scoped
cross join covered c
group by reply_class, c.window_start, c.window_end
order by case reply_class when 'fast' then 1 when 'slow' then 2 else 3 end
