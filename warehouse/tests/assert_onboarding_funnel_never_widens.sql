select
    cohort_month,
    invited,
    joined,
    active_by_day_1,
    active_by_day_7,
    active_by_day_30
from {{ ref('mart_onboarding_funnel') }}
where joined > invited
    or active_by_day_1 > joined
    or active_by_day_7 > joined
    or active_by_day_30 > joined
    or active_by_day_7 < active_by_day_1
    or active_by_day_30 < active_by_day_7
