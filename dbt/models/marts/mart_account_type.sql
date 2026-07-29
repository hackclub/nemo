with member_totals as (
    select
        user_id,
        sum(coalesce(messages_posted, 0)) as messages_posted
    from {{ ref('fct_member_activity') }}
    group by user_id
)

select
    m.account_type,
    count(*) as members,
    count(*) filter (where m.is_claimed) as claimed,
    sum(coalesce(act.messages_posted, 0)) as total_messages,
    'v6' as metric_version
from {{ ref('dim_member') }} m
left join member_totals act using (user_id)
where not m.is_bot
group by 1
order by members desc
