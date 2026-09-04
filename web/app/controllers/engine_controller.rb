class EngineController < ApplicationController
  before_action { needs(:analytics) }
  before_action :require_operating

  HISTORY = 12
  FRESHNESS_WINDOW = 30.days
  TYPICAL_OF = 10
  NIGHTS = 30
  VISIT_STEPS_NEED = 15

  TABS = { "runs" => "Runs", "sources" => "Sources", "coverage" => "Coverage",
           "backfill" => "Backfill", "tuning" => "Tuning" }.freeze

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
    @band = band_facts

    case @tab
    when "sources" then @sources = source_rows
    when "coverage" then coverage_facts
    when "tuning" then @sources = source_rows
    when "backfill" then backfill_facts
    end
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
      .where(started_at: nights.first.beginning_of_day..)
      .where.not(source: Analytics::FctIngestRun::PARENT_SOURCE)
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

  BandFact = Struct.new(:key, :value, :said, :tone, keyword_init: true)

  def band_facts
    held = consecutive_member_days
    behind = source_rows.select { |row| row.state == "stale" || row.state == "never run" }
    worst = behind.min_by { |row| row.last_ok || Time.at(0) }
    done = @steps.count(&:settled?)
    planned = @steps.last&.step_total || Engine::Source::KEYS.size

    [
      BandFact.new(key: "Consecutive member-days", value: held,
        said: "of #{VISIT_STEPS_NEED}, which is what the visit steps need",
        tone: held >= VISIT_STEPS_NEED ? "good" : ""),
      BandFact.new(key: "Behind", value: behind.size,
        said: worst ? "#{worst.source.key}, #{helpers.short_age(worst.last_ok)}" : "nothing",
        tone: behind.any? ? "bad" : "good"),
      BandFact.new(key: "Tonight", value: "#{done}/#{planned}",
        said: @run ? run_span(@run) : "not started", tone: "push")
    ]
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

  def last_success_by_stage(since = nil)
    scope = Analytics::FctIngestRun.where(status: "ok")
    scope = scope.where(finished_at: since..) if since
    scope
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
        next unless newest.fetch(stage) { newest[stage] = parent_run_id } == parent_run_id

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
