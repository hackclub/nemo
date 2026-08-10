select
    mode,
    seeded_at,
    seed_profile,
    seed_scale,
    seed_rng
from {{ source('raw', 'deployment') }}
