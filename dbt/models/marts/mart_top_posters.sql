select
    date_trunc('month', window_start)::date as month,
    window_start,
    window_end,
    (window_end - window_start + 1) as days_in_window,
    user_id,
    display_name,
    messages_posted,
    row_number() over (
        partition by window_start
        order by messages_posted desc, user_id
    ) as rank,
    'v1' as metric_version
from {{ ref('fct_top_posters') }}
order by window_start desc, rank
