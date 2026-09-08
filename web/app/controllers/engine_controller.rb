class EngineController < ApplicationController
  before_action { needs(:analytics) }
  before_action :require_operating

  HISTORY = 12
  FRESHNESS_WINDOW = 30.days
  SUCCESS_FLOOR = 60.days
  MATRIX_ROW_CAP = 50_000
  TYPICAL_OF = 10
  NIGHTS = 30
  VISIT_STEPS_NEED = 15

  TABS = { "runs" => "Runs", "sources" => "Sources", "coverage" => "Coverage",
           "queues" => "Queues", "backfill" => "Backfill", "archive" => "Archive",
           "faults" => "Faults", "tuning" => "Tuning" }.freeze
  MUTE_FOR = 1.day
  TAXONOMY_WINDOW = 30.days
  SLICE_STRIP_DAYS = 60
  DAY_SOURCES = %w[member_days channel_days].freeze

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "runs"
    @active_request = SyncRequest.active.recent_first.first
    @run = Analytics::FctIngestRun.parents.recent_first.first
    @orphaned = orphaned?
    @auto_refresh = (@run&.running? || @active_request.present?) && !@orphaned

    @may_tune = may_community?("ops.engine")
    @open = params[:open].presence
    @steps = @run ? steps_for(@run) : []
    @step_output = @run ? step_output_for(@run) : []
    @nights = night_dates
    @matrix = night_matrix(@nights)

    case @tab
    when "sources" then @sources = source_rows
    when "coverage" then coverage_facts
    when "queues" then queue_facts
    when "faults" then fault_facts
    when "tuning" then @sources = source_rows
    when "backfill" then backfill_facts
    when "archive" then archive_facts
    end
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
    SETTLED = %w[ok skipped].freeze

    def running?
      statuses.key?("running")
    end

    def settled?
      statuses.keys.all? { |status| SETTLED.include?(status) }
    end
  end

  STATUS_ORDER = %w[failed cancelled abandoned running ok].freeze

  def worker
    return @worker if defined?(@worker)

    @worker = Analytics::FctWorkerHeartbeat.sync_worker
  end

  def orphaned?
    return false unless @run&.running? || @active_request.present?

    worker.nil? || worker.cold?
  end

  def steps_for(run)
    Analytics::FctIngestRun
      .where(parent_run_id: run.id)
      .order(:step_index, :id)
      .group_by(&:step_index)
      .sort
      .map { |index, group| collapse_step(index, group) }
  end

  def collapse_step(index, group)
    sources = group.map(&:source).uniq
    landed = group.select { |row| %w[ok running].include?(row.status) }
    rows = landed.filter_map(&:rows_in)
    expected = landed.filter_map(&:total_expected)
    started = group.map(&:started_at).min
    finished = group.all?(&:finished_at) ? group.map(&:finished_at).max : Time.current
    shares = group.select(&:running?).filter_map(&:progress_share)

    StepGroup.new(
      source: sources.size == 1 ? sources.first : sources.first.split(":", 2).first,
      step_index: index,
      step_total: group.first.step_total,
      statuses: group.map(&:status).tally.sort_by { |status, _| STATUS_ORDER.index(status) || 99 }.to_h,
      children: group.size,
      rows_in: rows.empty? ? nil : rows.sum,
      total_expected: expected.empty? ? nil : expected.sum,
      seconds: (finished - started).to_i,
      pct: shares.empty? ? nil : (shares.sum.to_f / shares.size * 100).round(1)
    )
  end

  def step_output_for(run)
    Analytics::FctIngestStepOutput.where(parent_run_id: run.id).order(:step_index).to_a
  end

  def first_step_by_parent(run_ids)
    Analytics::FctIngestRun
      .where(parent_run_id: run_ids)
      .order(:step_index, :id)
      .group_by(&:parent_run_id)
      .transform_values(&:first)
  end

  def refuse_tuning
    redirect_to engine_path(tab: "tuning"),
      alert: Community::Access.why_not(current_account, "ops.engine")
  end

  def refuse_running
    redirect_to engine_path, alert: Community::Access.why_not(current_account, "ops.engine")
  end

  def stage_for_source(source)
    return nil if source == "nightly_sync"

    Engine::Source.for_run(source)&.key
  end

  def night_dates
    last = Date.current
    ((last - (NIGHTS - 1))..last).to_a
  end

  def night_matrix(nights)
    index = Hash.new { |store, key| store[key] = {} }

    Analytics::FctIngestRun
      .where(started_at: nights.first.beginning_of_day..Time.current.end_of_day)
      .where.not(source: Analytics::FctIngestRun::PARENT_SOURCE)
      .order(started_at: :desc)
      .limit(MATRIX_ROW_CAP)
      .pluck(:source, :status, :started_at)
      .each do |source, status, started_at|
        stage = stage_for_source(source)
        next unless stage

        on = started_at.to_date
        was = index[stage][on]
        index[stage][on] = status if was.nil? || RANK.fetch(status, 0) > RANK.fetch(was, 0)
      end

    Engine::Source.all.map do |source|
      cells = nights.map do |on|
        case index[source.key][on]
        when "ok" then "ok"
        when "running" then "run"
        when "skipped" then "skip"
        when nil then on == Date.current ? "wait" : "none"
        else "fail"
        end
      end
      [source, cells]
    end
  end

  RANK = { "skipped" => 1, "ok" => 2, "running" => 3, "cancelled" => 4, "abandoned" => 5,
           "failed" => 6 }.freeze

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
      .where(status: "ok")
      .where(finished_at: since..)
      .group(:source)
      .maximum(:finished_at)
      .filter_map { |source, finished_at| [stage_for_source(source), finished_at] if stage_for_source(source) }
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last).compact.max }
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

  def typical_seconds
    Analytics::FctIngestRun
      .where(status: "ok")
      .where.not(finished_at: nil)
      .where(started_at: FRESHNESS_WINDOW.ago..)
      .order(id: :desc)
      .pluck(:source, Arel.sql("extract(epoch from finished_at - started_at)"))
      .filter_map { |source, taken| [stage_for_source(source), taken.to_f] if stage_for_source(source) }
      .group_by(&:first)
      .transform_values { |pairs| median(pairs.map(&:last).first(TYPICAL_OF)) }
  end

  def last_rows_in
    newest = {}
    totals = {}

    Analytics::FctIngestRun
      .where(status: "ok")
      .where.not(rows_in: nil)
      .where(started_at: FRESHNESS_WINDOW.ago..)
      .order(id: :desc)
      .pluck(:source, :parent_run_id, :rows_in)
      .each do |source, parent_run_id, count|
        stage = stage_for_source(source)
        next unless stage

        first_seen = !totals.key?(stage)
        next if !first_seen && (parent_run_id.nil? || parent_run_id != newest[stage])

        newest[stage] = parent_run_id if first_seen
        totals[stage] = totals.fetch(stage, 0) + count
      end

    totals
  end

  def median(values)
    return nil if values.empty?

    sorted = values.sort
    sorted[sorted.size / 2]
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
