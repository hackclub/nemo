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
),
days as (
    select
        s.user_id,
        s.window_start,
        s.window_end,
        count(distinct a.window_start) filter (where a.messages_posted > 0)::integer as days_posted,
        count(distinct a.window_start)::integer as days_measured
    from scoped s
    left join {{ ref('fct_member_activity') }} a
        on a.user_id = s.user_id
        and a.window_start between s.window_start and s.window_end
    group by 1, 2, 3
)
select
    s.month,
    s.window_start,
    s.window_end,
    (s.window_end - s.window_start + 1) as days_in_window,
    s.user_id,
    s.display_name,
    s.messages_posted,
    d.days_posted,
    d.days_measured,
    row_number() over (
        partition by s.month
        order by s.messages_posted desc, s.user_id
    ) as rank,
    'v3' as metric_version
from scoped s
join days d
    on d.user_id = s.user_id
    and d.window_start = s.window_start
    and d.window_end = s.window_end
order by month desc, rank
