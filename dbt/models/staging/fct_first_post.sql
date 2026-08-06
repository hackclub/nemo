with searched as (
    select
        user_id,
        first_post_channel as channel_id,
        first_post_ts as posted_at,
        'search' as source
    from {{ ref('fct_member_history') }}
    where first_post_ts is not null
),

event_first_posts as (
    select
        user_id,
        channel_id,
        posted_at,
        'events' as source
    from (
        select
            user_id,
            channel_id,
            posted_at,
            row_number() over (partition by user_id order by posted_at) as rn
        from {{ ref('fct_message') }}
    ) ranked
    where rn = 1
      and user_id not in (select user_id from searched)
)

select * from searched
union all
select * from event_first_posts
