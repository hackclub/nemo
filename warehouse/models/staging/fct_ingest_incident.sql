with stage_runs as (
    select source_key, status, started_at, error_class, error_detail
    from {{ source('raw', 'ingest_run') }}
    where status in ('ok', 'partial', 'failed', 'abandoned')
      and source_key is not null
      and source_key <> 'nightly_sync'
      and not (status = 'abandoned' and error_class = 'local')
),

ranked as (
    select
        *,
        sum(case when status in ('ok', 'partial') then 1 else 0 end) over (
            partition by source_key
            order by started_at desc
            rows between unbounded preceding and current row
        ) as successes_since
    from stage_runs
),

failing_sources as (
    select
        'source_failing' as kind,
        source_key,
        count(*)::integer as consecutive,
        min(started_at) as first_seen,
        max(started_at) as last_seen,
        (array_agg(error_class order by started_at desc))[1] as error_class,
        (array_agg(error_detail order by started_at desc))[1] as error_detail
    from ranked
    where successes_since = 0 and status in ('failed', 'abandoned')
    group by source_key
),

credentials as (
    select
        'credential' as kind,
        worker as source_key,
        1 as consecutive,
        beat_at as first_seen,
        beat_at as last_seen,
        case when beat_at < now() - interval '10 minutes' then 'transport' else 'auth' end as error_class,
        case when beat_at < now() - interval '10 minutes'
             then 'proxy probe silent for ' || date_trunc('minute', now() - beat_at)::text
             else note end as error_detail
    from {{ source('raw', 'worker_heartbeat') }}
    where worker = 'proxy'
      and (note like 'FAILED%' or beat_at < now() - interval '10 minutes')
),

quality as (
    select
        'quality' as kind,
        subject || ':' || assertion as source_key,
        count(*)::integer as consecutive,
        min(checked_at) as first_seen,
        max(checked_at) as last_seen,
        'local' as error_class,
        (array_agg(observed || ' vs ' || expected order by checked_at desc))[1] as error_detail
    from {{ source('ingest', 'quality_result') }}
    where status = 'fail'
      and severity = 'error'
      and checked_at > now() - interval '2 days'
    group by subject, assertion
),

incidents as (
    select * from failing_sources
    union all select * from credentials
    union all select * from quality
)

select
    i.kind,
    i.source_key,
    i.consecutive,
    i.first_seen,
    i.last_seen,
    i.error_class,
    i.error_detail,
    a.acked_by,
    a.acked_at,
    a.muted_until,
    coalesce(a.muted_until > now(), false) as muted,
    'v1' as metric_version
from incidents i
left join {{ source('ingest', 'incident_ack') }} a
    on a.source_key = i.source_key and a.kind = i.kind
