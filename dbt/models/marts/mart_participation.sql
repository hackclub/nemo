select
    window_end,
    count(*) filter (where days_active > 0) as active_members,
    count(*) filter (where messages_posted > 0) as posting_members,
    round(
        count(*) filter (where messages_posted > 0)::numeric
        / nullif(count(*) filter (where days_active > 0), 0),
        4
    ) as posting_share,
    'v1' as metric_version
from {{ ref('fct_member_activity') }}
group by window_end
order by window_end
