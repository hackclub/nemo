select
    cohort_month,
    created_account,
    signed_in,
    posted_once,
    posted_twice,
    posted_three_times
from {{ ref('mart_onboarding_recurrence_funnel') }}
where signed_in > created_account
    or posted_once > signed_in
    or posted_twice > posted_once
    or posted_three_times > posted_twice
