with ranked as (
    select
        *,
        row_number() over (
            partition by date_trunc('month', ds) order by ds desc
        ) as rn
    from {{ ref('fct_team_stats') }}
)
select
    date_trunc('month', ds)::date as month,
    count(*) as days_covered,
    max(ds) as last_ds,

    sum(channel_messages_1d) as channel_messages,
    sum(chats_channels_count_1d) as public_channel_messages,
    sum(chats_groups_count_1d) as private_channel_messages,
    sum(messages_count_1d) as messages,
    sum(messages_from_members_1d) as messages_from_members,
    sum(messages_channels_count_from_apps_1d) as messages_from_apps,
    sum(files_count_1d) as files,

    max(active_users_28d) filter (where rn = 1) as active_users_28d,
    max(writers_count_28d) filter (where rn = 1) as writers_count_28d,
    max(channels_count) filter (where rn = 1) as channels_count,

    round(avg(active_users_1d)) as mean_daily_active,
    round(avg(writers_count_1d)) as mean_daily_writers,

    'v1' as metric_version
from ranked
group by 1
order by month
