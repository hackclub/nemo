class PipelineController < ApplicationController
  HISTORY = 12
  FRESHNESS_WINDOW = 30.days

  def index
    @run = Analytics::FctIngestRun.parents.recent_first.first
    @steps = @run ? steps_for(@run) : []
    @step_output = @run ? step_output_for(@run) : []
    @history = Analytics::FctIngestRun.parents.recent_first.limit(HISTORY)
    @history_kind = first_step_by_parent(@history.map(&:id))
    @freshness = Analytics::FctIngestRun
      .where(status: "ok")
      .where(finished_at: FRESHNESS_WINDOW.ago..)
      .pluck(:source, :finished_at)
      .filter_map { |source, finished_at| [stage_for_source(source), finished_at] if stage_for_source(source) }
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last).max }
      .sort_by { |_stage, at| at }
    @active_request = SyncRequest.active.recent_first.first
    @last_request = SyncRequest.recent_first.first
    @auto_refresh = @run&.running? || @active_request.present?
    @day_coverage = day_coverage
  end

  def show
    @run = Analytics::FctIngestRun.parents.find(params[:id])
    @steps = steps_for(@run)
    @step_output = step_output_for(@run)
  end

  def sync
    if SyncRequest.active.exists?
      redirect_to pipeline_path, alert: "a sync is already queued or running"
      return
    end

    SyncRequest.queue!(kind: "full", requested_by: current_staff.user_id)
    redirect_to pipeline_path, notice: "sync queued"
  end

  def cancel
    request = SyncRequest.active.recent_first.first
    if request&.cancel!
      redirect_to pipeline_path, notice: "cancel requested"
    else
      redirect_to pipeline_path, alert: "nothing to cancel"
    end
  end

  def trigger_stage
    if SyncRequest.active.exists?
      redirect_to pipeline_path, alert: "a sync is already queued or running"
      return
    end

    SyncRequest.queue!(kind: "stage", stage: params[:stage], requested_by: current_staff.user_id)
    redirect_to pipeline_path, notice: "#{params[:stage]} queued"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to pipeline_path, alert: e.record.errors.full_messages.to_sentence
  end

  private

  StepGroup = Struct.new(:source, :step_index, :step_total, :statuses, :children,
    :rows_in, :total_expected, :seconds, :pct, keyword_init: true) do
    def running?
      statuses.key?("running")
    end
  end

  STATUS_ORDER = %w[failed cancelled abandoned running ok].freeze

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

  SOURCE_TO_STAGE = {
    "admin_analytics_api:member" => "member_days",
    "admin_analytics_api:public_channel" => "channel_days",
    "admin_analytics_member_range" => "member_range",
    "admin_analytics_channel_range" => "channel_range",
    "channel_info_names" => "channel_names"
  }.freeze

  def stage_for_source(source)
    return nil if source == "nightly_sync"
    return SOURCE_TO_STAGE[source] if SOURCE_TO_STAGE.key?(source)

    prefix = source.split(":", 2).first
    SyncRequest::STAGES.include?(prefix) ? prefix : nil
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
