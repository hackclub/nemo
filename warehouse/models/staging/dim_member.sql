with scoped as (
    select
        m.user_id,
        coalesce(o.account_created_verified, m.account_created_verified) as account_created_verified,
        m.claimed_at,
        m.deactivated_at,
        m.invite_pending,
        m.is_invited_member,
        m.is_invited_guest,
        m.is_bot,
        m.is_admin,
        m.is_owner,
        m.is_primary_owner,
        m.is_restricted,
        m.is_ultra_restricted,
        case
            when coalesce(o.account_created_verified, m.account_created_verified) is not null
                then coalesce(o.account_created_verified, m.account_created_verified)
            when m.account_created > (
                select max(account_created_verified) from {{ source('raw', 'member_dim') }}
            ) then m.account_created
        end as cohort_at,
        coalesce(m.is_deleted, m.deactivated_at is not null) as resolved_is_deleted
    from {{ source('raw', 'member_dim') }} m
    left join {{ source('raw', 'member_created_override') }} o on o.user_id = m.user_id
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
