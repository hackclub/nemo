with observed as (
    select
        user_id,
        observed_on,
        record_hash,
        is_bot, is_admin, is_owner, is_primary_owner, is_restricted,
        is_ultra_restricted, is_invited_member, is_invited_guest,
        is_deleted, invite_pending, claimed_at, deactivated_at,
        account_created_verified,
        lag(record_hash) over (partition by user_id order by observed_on) as prior_hash
    from {{ source('raw', 'member_dim_snapshot') }}
),

changes as (
    select *, sum(case when prior_hash is distinct from record_hash then 1 else 0 end)
        over (partition by user_id order by observed_on) as version
    from observed
),

versions as (
    select
        user_id,
        version,
        min(observed_on) as valid_from,
        max(observed_on) as last_seen_on,
        min(record_hash) as record_hash,
        bool_or(is_bot) as is_bot,
        bool_or(is_admin) as is_admin,
        bool_or(is_owner) as is_owner,
        bool_or(is_primary_owner) as is_primary_owner,
        bool_or(is_restricted) as is_restricted,
        bool_or(is_ultra_restricted) as is_ultra_restricted,
        bool_or(is_invited_member) as is_invited_member,
        bool_or(is_invited_guest) as is_invited_guest,
        bool_or(is_deleted) as is_deleted,
        bool_or(invite_pending) as invite_pending,
        min(claimed_at) as claimed_at,
        max(deactivated_at) as deactivated_at,
        min(account_created_verified) as account_created_verified
    from changes
    group by user_id, version
)

select
    user_id,
    version,
    valid_from,
    lead(valid_from) over (partition by user_id order by version) as valid_to,
    lead(valid_from) over (partition by user_id order by version) is null as is_current,
    record_hash,
    is_bot, is_admin, is_owner, is_primary_owner, is_restricted,
    is_ultra_restricted, is_invited_member, is_invited_guest,
    is_deleted, invite_pending, claimed_at, deactivated_at,
    account_created_verified,
    last_seen_on
from versions
