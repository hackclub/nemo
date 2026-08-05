class PipelineController < ApplicationController
  HISTORY = 12
  FRESHNESS_WINDOW = 30.days

  def index
    @run = Analytics::FctIngestRun.parents.recent_first.first
    @steps = if @run
      Analytics::FctIngestRun.where(parent_run_id: @run.id).order(:step_index, :id)
    else
      Analytics::FctIngestRun.none
    end
    @step_output = if @run
      Analytics::FctIngestStepOutput.where(parent_run_id: @run.id).order(:step_index).to_a
    else
      []
    end
    @history = Analytics::FctIngestRun.parents.recent_first.limit(HISTORY)
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
