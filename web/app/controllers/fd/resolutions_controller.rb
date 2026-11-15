module Fd
  class ResolutionsController < BaseController
    include ClosesReports
    include UnmergesCases

    permit "case.resolve", on: -> { Case.find(params[:case_id]) }, only: :create
    permit "case.reopen", on: -> { Case.find(params[:case_id]) }, only: :destroy

    def create
      @case = Case.find(params[:case_id])
      @now = Time.current

      resolution = resolution_reason
      return redirect_with_alert("Select a resolution") if resolution.nil?

      resolved = false
      writing do
        next unless mark_resolved(resolution)

        resolved = true
        close_reports(@case, @now) if notify_reporter?
        @case.reload
        audit(@case, "resolved",
          before: { "resolved_at" => nil, "resolution" => nil },
          after: {
            "resolved_at" => @case.resolved_at,
            "resolution" => resolution,
            "duplicate_of" => @case.duplicate_of,
            "member_note" => @case.member_note
          })
      end

      if resolved
        redirect_to fd_case_path(@case), notice: "Case #{@case.id} resolved"
      else
        redirect_with_alert("Case #{@case.id} was already resolved")
      end
    end

    def destroy
      @case = Case.find(params[:case_id])
      @now = Time.current

      return redirect_with_alert("Case #{@case.id} is already open") unless @case.resolved?

      writing do
        unmerge(@case) if @case.duplicate?
        next unless @case.resolved?

        previous_state = { "resolved_at" => @case.resolved_at, "resolution" => @case.resolution }
        @case.update!(resolved_at: nil, resolution: nil, updated_at: @now)
        reopen_reports(@case)
        audit(@case, "reopened", before: previous_state, after: { "resolved_at" => nil, "resolution" => nil })
      end

      redirect_to fd_case_path(@case), notice: "Case #{@case.id} reopened"
    end

    private

    def resolution_reason
      return "action_taken" if Action.where(case_id: @case.family_ids).live.any?

      reason = params[:close_reason].to_s
      Case::CLOSE_REASONS.include?(reason) ? reason : nil
    end

    def mark_resolved(resolution)
      @case.mark_resolved!(resolution, at: @now, member_note: params[:member_note].presence)
    end

    def redirect_with_alert(message)
      redirect_to fd_case_path(@case), alert: message
    end
  end
end
