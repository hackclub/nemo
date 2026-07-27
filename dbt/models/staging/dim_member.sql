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
    is_guest,
    coalesce(account_created_verified, account_created) as account_created,
    account_created_verified,
    claimed_at,
    deactivated_at,
    claimed_at is not null or coalesce(claimed_no_date, false) as is_claimed,
    coalesce(is_bot, false) as is_bot
from {{ source('raw', 'member_dim') }}
