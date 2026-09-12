class EngineController < ApplicationController
  before_action { needs(:analytics) }
  before_action :require_operating

  FRESHNESS_WINDOW = 30.days
  SUCCESS_FLOOR = 60.days
  TYPICAL_OF = 10
  NIGHTS = 30

  TABS = { "runs" => "Runs", "sources" => "Sources", "coverage" => "Coverage",
           "queues" => "Queues", "backfill" => "Backfill", "archive" => "Archive",
           "faults" => "Faults", "tuning" => "Tuning" }.freeze
  GROUPS = { "The night" => %w[runs sources], "What landed" => %w[coverage archive],
             "Work waiting" => %w[queues backfill],
             "Whether to trust it" => %w[faults tuning] }.freeze
  MUTE_FOR = 1.day
  TAXONOMY_WINDOW = 30.days
  SLICE_STRIP_DAYS = 60
  DAY_SOURCES = %w[member_days channel_days].freeze
  NIGHT_TABS = %w[runs sources].freeze

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "runs"
    @active_request = SyncRequest.active.recent_first.first
    @run = Analytics::FctIngestRun.parents.recent_first.first
    @orphaned = orphaned?
    @auto_refresh = (@run&.running? || @active_request.present?) && !@orphaned

    @may_tune = may_community?("ops.engine")
    @progress = @run&.running? ? run_progress(@run) : nil

    if NIGHT_TABS.include?(@tab)
      @nights = night_dates
      @matrix = night_matrix(@nights)
    end

    case @tab
    when "runs" then @steps = @run ? steps_for(@run) : []
    when "sources" then source_facts
    when "coverage" then coverage_facts
    when "queues" then queue_facts
    when "faults" then fault_facts
    when "tuning" then @sources = source_rows
    when "backfill" then backfill_facts
    when "archive" then archive_facts
    end
  end

  def source_facts
    @open = params[:open].presence
    @sources = source_rows
    @step_output = @run ? step_output_for(@run) : []
  end

  def archive_facts
    @archive = Engine::Archive.report
  end

  def queue_facts
    @queues = Analytics::FctWorkQueue.busiest_first.to_a
  end

  def fault_facts
    @incidents = Analytics::FctIngestIncident.worst_first.to_a
    @breakers = latest_quality("breaker")
    @local_faults = latest_quality("invariant", "work_queue").select { |row| row.status == "fail" }
    @taxonomy = fault_taxonomy
    @beats = Analytics::FctWorkerHeartbeat.order(:worker).to_a
    @breaker_mode = Engine::Setting.value(Engine::Setting::ENGINE, "breaker_mode")
  end

  def ack_incident
    return refuse_tuning unless may_community?("ops.engine")

    row = remember_incident(params[:source_key], params[:kind], muted_until: nil)
    redirect_to engine_path(tab: "faults"), notice: "#{row.source_key} acknowledged"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to engine_path(tab: "faults"), alert: e.record.errors.full_messages.to_sentence
  end

  def mute_incident
    return refuse_tuning unless may_community?("ops.engine")

    row = remember_incident(params[:source_key], params[:kind], muted_until: MUTE_FOR.from_now)
    redirect_to engine_path(tab: "faults"), notice: "#{row.source_key} muted for a day"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to engine_path(tab: "faults"), alert: e.record.errors.full_messages.to_sentence
  end

  def override_breaker
    return refuse_tuning unless may_community?("ops.engine")

    row = remember_incident(params[:source_key], "breaker", muted_until: MUTE_FOR.from_now)
    redirect_to engine_path(tab: "faults"), notice: "breaker #{row.source_key} held closed for a night"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to engine_path(tab: "faults"), alert: e.record.errors.full_messages.to_sentence
  end

  HOLDING = [["Recurrence funnel, visit steps", 15], ["Retention, day 30", 30],
             ["Retention, day 90", 90]].freeze

  def backfill_facts
    @backfills = ChannelBackfill.order(
      Arel.sql("case state when 'draining' then 1 when 'queued' then 2 " \
               "when 'paused' then 3 when 'complete' then 4 else 5 end"),
      :priority, :requested_at
    ).to_a
    ids = @backfills.map(&:channel_id)
    @backfill_names = ids.any? ? Analytics::DimChannel.where(channel_id: ids)
      .pluck(:channel_id, :name).to_h : {}
    @backfill_queued_requests = ChannelBackfill.open_work.sum(:estimated_requests)
  end

  def coverage_facts
    @day_coverage = day_coverage
    @held = consecutive_member_days
    @slices = slice_summary
    @day_strips = day_strips
  end

  def tune
    return refuse_tuning unless may_community?("ops.engine")

    row = Engine::Setting.set!(params[:source], params[:name], params[:value],
      by: current_account.user_id)
    Fd::Audit.record(row, "tuned",
      actor: current_account.user_id, request_id: request.request_id,
      after: { "source" => row.source, "name" => row.name, "value" => row.value })

    redirect_to engine_path(tab: "tuning"), notice: "#{row.name} is #{row.value}"
  rescue Engine::Setting::Refused, Engine::Source::Unknown => e
    redirect_to engine_path(tab: "tuning"), alert: e.message
  end

  def untune
    return refuse_tuning unless may_community?("ops.engine")

    row = Engine::Setting.reset!(params[:source], params[:name], by: current_account.user_id)
    if row
      Fd::Audit.record(row, "reset",
        actor: current_account.user_id, request_id: request.request_id,
        after: { "source" => row.source, "name" => row.name })
    end

    redirect_to engine_path(tab: "tuning"), notice: "#{params[:name]} is back to the file"
  end

  def show
    @tab = "runs"
    @run = Analytics::FctIngestRun.parents.find(params[:id])
    @steps = steps_for(@run)
    @step_output = step_output_for(@run)
    @orphaned = orphaned?
  end

  def sync
    return refuse_running unless may_community?("ops.engine")

    if SyncRequest.active.exists?
      redirect_to engine_path, alert: "a sync is already queued or running"
      return
    end

    SyncRequest.queue!(kind: "full", requested_by: current_account.user_id)
    redirect_to engine_path, notice: "sync queued"
  rescue SyncRequest::AlreadyRunning => e
    redirect_to engine_path, alert: e.message
  end

  def cancel
    return refuse_running unless may_community?("ops.engine")

    @active_request = SyncRequest.active.recent_first.first
    gone = orphaned?
    if @active_request&.cancel!(worker_gone: gone)
      redirect_to engine_path, notice: gone ? "released, no worker" : "cancel requested"
    else
      redirect_to engine_path, alert: "nothing to cancel"
    end
  end

  def trigger_stage
    return refuse_running unless may_community?("ops.engine")

    if SyncRequest.active.exists?
      redirect_to engine_path, alert: "a sync is already queued or running"
      return
    end

    SyncRequest.queue!(kind: "stage", stage: params[:stage], requested_by: current_account.user_id)
    redirect_to engine_path, notice: "#{params[:stage]} queued"
  rescue SyncRequest::AlreadyRunning => e
    redirect_to engine_path, alert: e.message
  rescue ActiveRecord::RecordInvalid => e
    redirect_to engine_path, alert: e.record.errors.full_messages.to_sentence
  end

  private

  StepGroup = Struct.new(:source, :step_index, :step_total, :statuses, :children,
    :rows_in, :total_expected, :seconds, :pct, keyword_init: true) do
    def running?
      statuses.key?("running")
    end
  end

  STATUS_ORDER = %w[failed cancelled abandoned running ok].freeze
  STATUSES = %w[running ok failed skipped partial cancelled abandoned].freeze

  def worker
    return @worker if defined?(@worker)

    @worker = Analytics::FctWorkerHeartbeat.sync_worker
  end

  def orphaned?
    return false unless @run&.running? || @active_request.present?

    worker.nil? || worker.cold?
  end

  STEPS_SQL = <<~SQL.freeze
    SELECT step_index,
           (array_agg(source ORDER BY id))[1]                             AS first_source,
           count(DISTINCT source)                                         AS sources,
           (array_agg(step_total ORDER BY id))[1]                         AS step_total,
           count(*)                                                       AS children,
           count(*) FILTER (WHERE finished_at IS NULL)                    AS unfinished,
           min(started_at)                                                AS started_at,
           max(finished_at)                                               AS finished_at,
           sum(rows_in) FILTER (WHERE status IN ('ok', 'running'))        AS rows_in,
           sum(total_expected) FILTER (WHERE status IN ('ok', 'running')) AS total_expected,
           avg(progress_share) FILTER (WHERE status = 'running')          AS share,
           #{STATUSES.map { |s| "count(*) FILTER (WHERE status = '#{s}') AS #{s}" }.join(",\n       ")}
    FROM   analytics.fct_ingest_run
    WHERE  parent_run_id = :parent
    GROUP  BY step_index
    ORDER  BY step_index
  SQL

  def steps_for(run)
    ApplicationRecord.connection
      .select_all(ApplicationRecord.sanitize_sql([STEPS_SQL, parent: run.id]))
      .map { |row| collapse_step(row) }
  end

  def collapse_step(row)
    source = row["first_source"]
    finished = row["unfinished"].to_i.zero? ? row["finished_at"]&.to_time : Time.current
    started = row["started_at"].to_time

    StepGroup.new(
      source: row["sources"].to_i == 1 ? source : source.split(":", 2).first,
      step_index: row["step_index"].to_i,
      step_total: row["step_total"]&.to_i,
      statuses: step_statuses(row),
      children: row["children"].to_i,
      rows_in: row["rows_in"]&.to_i,
      total_expected: row["total_expected"]&.to_i,
      seconds: ((finished || started) - started).to_i,
      pct: row["share"] ? (row["share"].to_f * 100).round(1) : nil
    )
  end

  def step_statuses(row)
    STATUSES.filter_map { |status| [status, row[status].to_i] if row[status].to_i.positive? }
      .sort_by { |status, _| STATUS_ORDER.index(status) || 99 }
      .to_h
  end

  def step_output_for(run)
    Analytics::FctIngestStepOutput.where(parent_run_id: run.id).order(:step_index).to_a
  end

  Progress = Struct.new(:step_index, :step_total, keyword_init: true)

  def run_progress(run)
    index, total = Analytics::FctIngestRun.where(parent_run_id: run.id)
      .order(step_index: :desc).limit(1).pick(:step_index, :step_total)
    return nil if index.nil?

    Progress.new(step_index: index, step_total: total)
  end

  def refuse_tuning
    redirect_to engine_path(tab: "tuning"),
      alert: Community::Access.why_not(current_account, "ops.engine")
  end

  def refuse_running
    redirect_to engine_path, alert: Community::Access.why_not(current_account, "ops.engine")
  end

  def night_dates
    last = Date.current
    ((last - (NIGHTS - 1))..last).to_a
  end

  def night_matrix(nights)
    worst = worst_by_night(nights)

    Engine::Source.all.map do |source|
      cells = nights.map do |on|
        rank = worst.dig(source.key, on)
        next (on == Date.current ? "wait" : "none") if rank.nil?

        CELL_BY_RANK.fetch(rank, "fail")
      end
      [source, cells]
    end
  end

  def worst_by_night(nights)
    index = Hash.new { |store, key| store[key] = {} }

    Analytics::FctIngestRun
      .where(logical_date: nights.first..nights.last, source_key: Engine::Source::KEYS)
      .group(:source_key, :logical_date)
      .pluck(:source_key, :logical_date, Arel.sql("max(#{RANK_SQL})"))
      .each { |key, on, rank| index[key][on] = rank }

    index
  end

  RANK = { "skipped" => 1, "ok" => 2, "running" => 3, "cancelled" => 4, "abandoned" => 5,
           "failed" => 6 }.freeze

  RANK_SQL = ["case status",
              *RANK.map { |status, rank| "when '#{status}' then #{rank}" },
              "else 0 end"].join(" ").freeze

  CELL_BY_RANK = { 1 => "skip", 2 => "ok", 3 => "run" }.freeze

  def remember_incident(source_key, kind, muted_until:)
    row = Ingest::IncidentAck.find_or_initialize_by(source_key: source_key.to_s, kind: kind.to_s)
    row.update!(acked_by: current_account.user_id, acked_at: Time.current, muted_until: muted_until)
    Fd::Audit.record(row, muted_until ? "muted" : "acked",
      actor: current_account.user_id, request_id: request.request_id,
      after: { "source_key" => row.source_key, "kind" => row.kind,
               "muted_until" => row.muted_until&.iso8601 })
    row
  end

  def latest_quality(*subjects)
    Analytics::FctQualityResult.where(subject: subjects)
      .where("checked_at > ?", 2.days.ago)
      .order(checked_at: :desc)
      .to_a
      .uniq { |row| [row.subject, row.assertion] }
  end

  Taxon = Struct.new(:error_class, :count, :sources, :sample, keyword_init: true)

  def fault_taxonomy
    Analytics::FctIngestRun.where(status: "failed")
      .where.not(parent_run_id: nil)
      .where("started_at > ?", TAXONOMY_WINDOW.ago)
      .group(:error_class)
      .pluck(:error_class, Arel.sql("count(*)"), Arel.sql("count(distinct source_key)"),
        Arel.sql("(array_agg(left(error_detail, 140) order by started_at desc))[1]"))
      .map { |klass, count, sources, sample|
        Taxon.new(error_class: klass || "unclassified", count: count, sources: sources, sample: sample)
      }
      .sort_by { |taxon| -taxon.count }
  end

  SliceSummary = Struct.new(:source_key, :complete, :short, :claimed, :superseded, :unavailable,
    :latest, :worst_ratio, :settled_week, keyword_init: true)

  def slice_summary
    Analytics::FctSliceCoverage.group(:source_key).pluck(
      :source_key,
      Arel.sql("count(*) filter (where state = 'complete')"),
      Arel.sql("count(*) filter (where state = 'short')"),
      Arel.sql("count(*) filter (where state = 'claimed')"),
      Arel.sql("count(*) filter (where state = 'superseded')"),
      Arel.sql("count(*) filter (where state = 'unavailable')"),
      Arel.sql("max(slice_end)"),
      Arel.sql("min(landed_ratio) filter (where state in ('complete', 'short'))"),
      Arel.sql("count(*) filter (where state = 'complete' and settled_at > now() - interval '7 days')")
    ).map { |key, complete, short, claimed, superseded, unavailable, latest, ratio, week|
      SliceSummary.new(source_key: key, complete: complete, short: short, claimed: claimed,
        superseded: superseded, unavailable: unavailable, latest: latest, worst_ratio: ratio,
        settled_week: week)
    }.sort_by(&:source_key)
  end

  def day_strips
    since = SLICE_STRIP_DAYS.days.ago.to_date
    by_source = Analytics::FctSliceCoverage.where(source_key: DAY_SOURCES)
      .where("slice_start >= ?", since)
      .pluck(:source_key, :slice_start, :state)
      .group_by(&:first)
      .transform_values { |rows| rows.to_h { |_, day, state| [day, state] } }
    DAY_SOURCES.filter_map do |key|
      states = by_source[key]
      next nil if states.nil?

      days = (since..Date.current).map { |day| [day, states[day] || "missing"] }
      missing = days.count { |_, state| %w[missing short claimed].include?(state) }
      per_day = @slices&.find { |row| row.source_key == key }&.settled_week.to_f / 7
      eta = per_day.positive? && missing.positive? ? (missing / per_day).ceil : nil
      [key, days, missing, per_day, eta]
    end
  end

  MEMBER_DAY_SOURCE = "member_day".freeze

  def consecutive_member_days
    days = Analytics::FctAnalyticsDay
      .where(source: MEMBER_DAY_SOURCE, loaded: true)
      .order(ds: :desc)
      .pluck(:ds)
    return 0 if days.empty?

    run = 1
    days.each_cons(2) do |later, earlier|
      break unless (later - earlier).to_i == 1

      run += 1
    end
    run
  end

  def run_span(run)
    seconds = run.seconds
    return "n/a" if seconds.nil?

    seconds < 60 ? "#{seconds}s" : "#{seconds / 60}m"
  end

  def last_success_by_stage(since = SUCCESS_FLOOR.ago)
    Analytics::FctIngestRun
      .where(status: "ok", source_key: Engine::Source::KEYS)
      .where(finished_at: since..)
      .group(:source_key)
      .maximum(:finished_at)
  end

  SourceRow = Struct.new(:source, :last_ok, :typical, :rows, :state, keyword_init: true)

  def source_rows
    return @source_rows if defined?(@source_rows)

    @source_rows = build_source_rows
  end

  def build_source_rows
    last_ok = last_success_by_stage
    seconds = typical_seconds
    rows = last_rows_in

    Engine::Source.all.map do |source|
      finished_at = last_ok[source.key]
      SourceRow.new(
        source: source,
        last_ok: finished_at,
        typical: seconds[source.key],
        rows: rows[source.key],
        state: finished_at.nil? ? "never run" : (source.stale?(finished_at) ? "stale" : "live")
      )
    end
  end

  TYPICAL_SQL = <<~SQL.freeze
    SELECT s.source_key,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY recent.seconds) AS typical
    FROM   unnest(ARRAY[:keys]::text[]) AS s(source_key)
    CROSS  JOIN LATERAL (
      SELECT extract(epoch FROM finished_at - started_at) AS seconds
      FROM   analytics.fct_ingest_run
      WHERE  source_key = s.source_key AND status = 'ok'
        AND  finished_at IS NOT NULL AND finished_at >= :since
      ORDER  BY finished_at DESC
      LIMIT  :of
    ) recent
    GROUP  BY s.source_key
  SQL

  def typical_seconds
    rows = ApplicationRecord.connection.select_rows(
      ApplicationRecord.sanitize_sql([TYPICAL_SQL, keys: Engine::Source::KEYS,
                                      since: FRESHNESS_WINDOW.ago, of: TYPICAL_OF])
    )
    rows.filter_map { |key, typical| [key, typical.to_f] if typical }.to_h
  end

  ROWS_IN_SQL = <<~SQL.freeze
    WITH newest AS (
      SELECT s.source_key, latest.parent_run_id, latest.rows_in
      FROM   unnest(ARRAY[:keys]::text[]) AS s(source_key)
      CROSS  JOIN LATERAL (
        SELECT parent_run_id, rows_in
        FROM   analytics.fct_ingest_run
        WHERE  source_key = s.source_key AND status = 'ok'
          AND  rows_in IS NOT NULL AND finished_at >= :since
        ORDER  BY finished_at DESC
        LIMIT  1
      ) latest
    )
    SELECT n.source_key,
           CASE WHEN n.parent_run_id IS NULL THEN n.rows_in
                ELSE (SELECT sum(rows_in) FROM analytics.fct_ingest_run sibling
                      WHERE sibling.parent_run_id = n.parent_run_id
                        AND sibling.source_key = n.source_key
                        AND sibling.status = 'ok' AND sibling.rows_in IS NOT NULL)
           END AS rows_in
    FROM   newest n
  SQL

  def last_rows_in
    rows = ApplicationRecord.connection.select_rows(
      ApplicationRecord.sanitize_sql([ROWS_IN_SQL, keys: Engine::Source::KEYS,
                                      since: FRESHNESS_WINDOW.ago])
    )
    rows.filter_map { |key, count| [key, count.to_i] if count }.to_h
  end

  DayCoverage = Struct.new(:source, :loaded, :unavailable, :never_fetched, :span, :first_ds, :last_ds, keyword_init: true)

  def day_coverage
    Analytics::FctAnalyticsDay.group(:source).pluck(
      :source,
      Arel.sql("count(*) filter (where loaded)"),
      Arel.sql("count(*) filter (where unavailable)"),
      Arel.sql("min(ds)"),
      Arel.sql("max(ds)"),
      Arel.sql("count(*)")
    ).map do |source, loaded, unavailable, first_ds, last_ds, total|
      span = (last_ds - first_ds).to_i + 1
      DayCoverage.new(
        source: source, loaded: loaded, unavailable: unavailable,
        never_fetched: span - total, span: span, first_ds: first_ds, last_ds: last_ds
      )
    end.sort_by(&:source)
  end
end
