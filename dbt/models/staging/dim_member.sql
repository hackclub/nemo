with scoped as (
    select
        *,
        case
            when account_created_verified is not null then account_created_verified
            when account_created > (
                select max(account_created_verified) from {{ source('raw', 'member_dim') }}
            ) then account_created
        end as cohort_at
    from {{ source('raw', 'member_dim') }}
)

select
    user_id,
    case
        when coalesce(is_bot, false) then 'Bot'
        when coalesce(is_primary_owner, false) then 'Org Owner'
        when coalesce(is_owner, false) then 'Owner'
        when coalesce(is_admin, false) then 'Admin'
        when coalesce(is_ultra_restricted, false) then 'Single-Channel Guest'
        when coalesce(is_restricted, false) then 'Multi-Channel Guest'
        else 'Member'
    end as account_type,
    account_created_verified,
    cohort_at,
    claimed_at,
    deactivated_at,
    case
        when account_created_verified is not null then claimed_at is not null
        when cohort_at is not null then invite_pending is false
        else false
    end as is_claimed,
    is_invited_member,
    is_invited_guest,
    coalesce(is_bot, false) as is_bot,
    coalesce(is_deleted, true) as is_deleted,
    not coalesce(is_deleted, true) and not coalesce(is_bot, false) as is_live
from scoped
