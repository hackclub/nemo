with items as (
    select * from {{ source('ingest', 'work_item') }}
),

per_kind as (
    select
        work_kind,
        count(*) filter (where state = 'pending') as pending,
        count(*) filter (where state = 'claimed') as claimed,
        count(*) filter (where state = 'complete') as complete,
        count(*) filter (where state = 'short') as short,
        count(*) filter (where state = 'unavailable') as unavailable,
        count(*) filter (where state = 'dead') as dead,
        min(created_at) filter (where state = 'pending') as oldest_pending_at,
        count(*) filter (where created_at > now() - interval '1 hour') as arrived_last_hour,
        count(*) filter (where created_at > now() - interval '24 hours') as arrived_last_day,
        count(*) filter (where settled_at > now() - interval '1 hour') as settled_last_hour,
        count(*) filter (where settled_at > now() - interval '24 hours') as settled_last_day,
        max(settled_at) as last_settled_at,
        max(updated_at) as updated_at
    from items
    group by work_kind
)

select
    *,
    case
        when settled_last_hour > 0 then round(60.0 * pending / settled_last_hour, 1)
        when settled_last_day > 0 then round(24.0 * 60.0 * pending / settled_last_day, 1)
    end as eta_minutes
from per_kind
