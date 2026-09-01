with observed as (
    select
        channel_id,
        observed_on,
        record_hash,
        name, visibility, archived, date_created,
        lag(record_hash) over (partition by channel_id order by observed_on) as prior_hash
    from {{ source('raw', 'channel_dim_snapshot') }}
),

changes as (
    select *, sum(case when prior_hash is distinct from record_hash then 1 else 0 end)
        over (partition by channel_id order by observed_on) as version
    from observed
),

versions as (
    select
        channel_id,
        version,
        min(observed_on) as valid_from,
        max(observed_on) as last_seen_on,
        min(record_hash) as record_hash,
        min(name) as name,
        min(visibility) as visibility,
        bool_or(archived) as archived,
        min(date_created) as date_created
    from changes
    group by channel_id, version
)

select
    channel_id,
    version,
    valid_from,
    lead(valid_from) over (partition by channel_id order by version) as valid_to,
    lead(valid_from) over (partition by channel_id order by version) is null as is_current,
    record_hash, name, visibility, archived, date_created, last_seen_on
from versions
