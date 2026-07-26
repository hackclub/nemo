select
    m.account_type,
    m.is_guest,
    count(*) as members,
    count(*) filter (where m.is_claimed) as claimed,
    sum(coalesce(act.messages_posted, 0)) as total_messages,
    'v2' as metric_version
from {{ ref('dim_member') }} m
left join {{ ref('fct_member_activity') }} act using (user_id)
group by 1, 2
order by members desc
