select
    worker,
    beat_at,
    note
from {{ source('raw', 'worker_heartbeat') }}
