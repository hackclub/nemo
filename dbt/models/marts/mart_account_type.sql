select
    m.account_type,
    count(*) as members,
    count(*) filter (where m.is_claimed) as claimed,
    sum(coalesce(act.messages_posted, 0)) as total_messages,
    'v4' as metric_version
from {{ ref('dim_member') }} m
left join {{ ref('fct_member_activity') }} act using (user_id)
where not m.is_bot
group by 1
order by members desc
