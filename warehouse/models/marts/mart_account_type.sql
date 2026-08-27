with counted_through as (
    select max(window_end) as window_end, min(window_start) as window_start
    from {{ ref('fct_member_window') }}
)

select
    m.account_type,
    count(*) as members,
    count(*) filter (where m.is_claimed) as claimed,
    c.window_start,
    c.window_end,
    'v10' as metric_version
from {{ ref('dim_member') }} m
cross join counted_through c
where m.is_live
group by 1, c.window_start, c.window_end
order by members desc
