with scoped as (
    select
        user_id,
        account_created_verified,
        claimed_at,
        deactivated_at,
        invite_pending,
        is_invited_member,
        is_invited_guest,
        is_bot,
        is_admin,
        is_owner,
        is_primary_owner,
        is_restricted,
        is_ultra_restricted,
        case
            when account_created_verified is not null then account_created_verified
            when account_created > (
                select max(account_created_verified) from {{ source('raw', 'member_dim') }}
            ) then account_created
        end as cohort_at,
        coalesce(is_deleted, deactivated_at is not null) as resolved_is_deleted
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
    not coalesce(invite_pending, false) as is_claimed,
    is_invited_member,
    is_invited_guest,
    coalesce(invite_pending, false) as invite_pending,
    coalesce(is_bot, false) as is_bot,
    resolved_is_deleted as is_deleted,
    not resolved_is_deleted and not coalesce(is_bot, false) as is_live
from scoped
