select cohort_key, channel_id, count(*) as rows_found
from {{ ref('mart_newcomer_channels') }}
group by cohort_key, channel_id
having count(*) > 1
