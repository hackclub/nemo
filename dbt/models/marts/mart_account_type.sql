select
    m.account_type,
    count(*) as members,
    count(*) filter (where m.is_claimed) as claimed,
    'v9' as metric_version
from {{ ref('dim_member') }} m
where m.is_live
group by 1
order by members desc
