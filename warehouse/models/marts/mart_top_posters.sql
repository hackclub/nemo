with latest_window as (
    select
        date_trunc('month', window_start)::date as month,
        max(window_end) as window_end
    from {{ ref('fct_top_posters') }}
    group by 1
),
scoped as (
    select
        latest_window.month,
        f.window_start,
        f.window_end,
        f.user_id,
        f.display_name,
        f.messages_posted
    from {{ ref('fct_top_posters') }} f
    join latest_window
        on latest_window.month = date_trunc('month', f.window_start)::date
        and latest_window.window_end = f.window_end
)
select
    month,
    window_start,
    window_end,
    (window_end - window_start + 1) as days_in_window,
    user_id,
    display_name,
    messages_posted,
    row_number() over (
        partition by month
        order by messages_posted desc, user_id
    ) as rank,
    'v2' as metric_version
from scoped
order by month desc, rank
