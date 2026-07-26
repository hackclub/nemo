select
    count(*) as invited,
    count(*) filter (where is_claimed) as claimed,
    round(
        count(*) filter (where is_claimed)::numeric
        / nullif(count(*), 0),
        4
    ) as claim_rate,
    'v2' as metric_version
from {{ ref('dim_member') }}
