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
    @history = Analytics::FctIngestRun.parents.recent_first.limit(HISTORY)
    @freshness = Analytics::FctIngestRun
      .where(status: "ok")
      .where(finished_at: FRESHNESS_WINDOW.ago..)
      .group(Arel.sql("split_part(source, ':', 1)"))
      .maximum(:finished_at)
      .sort_by { |_stage, at| at }
    @active_request = SyncRequest.active.recent_first.first
    @last_request = SyncRequest.recent_first.first
    @auto_refresh = @run&.running? || @active_request.present?
  end

  def sync
    if SyncRequest.active.exists?
      redirect_to pipeline_path, alert: "a sync is already queued or running"
      return
    end

    SyncRequest.queue!(kind: "full", requested_by: current_staff.user_id)
    redirect_to pipeline_path, notice: "sync queued"
  end
end
