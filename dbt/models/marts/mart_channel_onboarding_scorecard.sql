with newcomer_first_posts as (
    select
        f.user_id,
        f.channel_id,
        date_trunc('month', f.posted_at)::date as post_month
    from {{ ref('fct_first_post') }} f
    inner join {{ ref('dim_member') }} d on d.user_id = f.user_id
    where not d.is_bot
),

reply_info as (
    select
        newcomer_id,
        latency_seconds < 3600 and not replied_by_bot as fast_reply
    from {{ ref('fct_first_reply') }}
),

member_join as (
    select
        user_id,
        claimed_at
    from {{ ref('dim_member') }}
    where claimed_at is not null
),

scorecard_rows as (
    select
        nfp.channel_id,
        nfp.post_month,
        nfp.user_id,
        ri.fast_reply,
        exists (
            select 1 from {{ ref('fct_member_activity') }} a
            where a.user_id = nfp.user_id
                and coalesce(a.days_active, 0) > 0
                and a.window_start between mj.claimed_at::date + 83 and mj.claimed_at::date + 90
        ) as retained_day_90,
        exists (
            select 1 from {{ ref('fct_member_activity') }} d
            where d.window_start between mj.claimed_at::date + 83 and mj.claimed_at::date + 90
        ) as day_90_covered
    from newcomer_first_posts nfp
    left join member_join mj on mj.user_id = nfp.user_id
    left join reply_info ri on ri.newcomer_id = nfp.user_id
)

select
    r.channel_id,
    c.name as channel_name,
    r.post_month,
    count(*) as newcomer_volume,
    count(*) filter (where r.fast_reply) as fast_reply_count,
    round(count(*) filter (where r.fast_reply)::numeric / nullif(count(*), 0), 4) as fast_reply_share,
    case when count(*) filter (where not r.day_90_covered) = 0
         then count(*) filter (where r.retained_day_90) end as retained_90_count,
    case when count(*) filter (where not r.day_90_covered) = 0
         then round(count(*) filter (where r.retained_day_90)::numeric / nullif(count(*), 0), 4)
    end as retained_90_share,
    (r.post_month + interval '1 month' + interval '90 days') <= now()
        and count(*) filter (where not r.day_90_covered) = 0 as day_90_mature,
    'v3' as metric_version
from scorecard_rows r
left join {{ ref('dim_channel') }} c on c.channel_id = r.channel_id
group by r.channel_id, c.name, r.post_month
order by r.post_month, r.channel_id
