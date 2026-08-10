select
    cohort_month,
    invited,
    joined,
    first_post,
    retained_day_30,
    retained_day_90
from {{ ref('mart_onboarding_funnel') }}
where joined > invited
    or first_post > joined
    or retained_day_30 > first_post
    or retained_day_90 > retained_day_30
