module Fd
  class ResolutionsController < BaseController
    permit "case.resolve", on: -> { Case.find(params[:case_id]) }, only: :create
    permit "case.reopen", on: -> { Case.find(params[:case_id]) }, only: :destroy

    def create
      @case = Case.find(params[:case_id])
      @now = Time.current

      resolution = ending
      return refuse("say why this case is closing") if resolution.nil?

      settled = false
      writing do
        next unless mark_resolved(resolution)

        settled = true
        close_reports if telling?
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

      if settled
        redirect_to fd_case_path(@case), notice: "case #{@case.id} resolved"
      else
        refuse(refusal(@case.reload))
      end
    end

    def destroy
      @case = Case.find(params[:case_id])
      @now = Time.current

      return refuse("case #{@case.id} is already open") unless @case.resolved?

      held = @case.assignee_user_ids
      was = { "resolved_at" => @case.resolved_at, "resolution" => @case.resolution,
              "duplicate_of" => @case.duplicate_of,
              "followed_decision_id" => @case.followed_decision_id,
              "assignees" => held }

      writing do
        @case.update!(resolved_at: nil, resolution: nil, duplicate_of: nil,
          followed_decision_id: nil, updated_at: @now)
        @case.assignees.destroy_all
        audit(@case, "reopened", before: was,
          after: { "resolved_at" => nil, "resolution" => nil, "duplicate_of" => nil,
                   "followed_decision_id" => nil, "assignees" => [] })
      end

      redirect_to fd_case_path(@case), notice: "case #{@case.id} is open again"
    end

    private

    def ending
      return "action_taken" if @case.actions.live.any?

      reason = params[:close_reason].to_s
      Case::CLOSE_REASONS.include?(reason) ? reason : nil
    end

    def telling?
      params[:tell_reporter] == "1"
    end

    def told
      said = params[:member_message].to_s.strip
      said.presence || Resolution::TOLD
    end

    def mark_resolved(resolution)
      Case.where(id: @case.id, resolved_at: nil)
        .update_all(
          resolved_at: @now,
          resolution: resolution,
          member_note: params[:member_note].presence,
          updated_at: @now
        ).positive?
    end

    def close_reports
      said = told

      @case.reports.where(closed_at: nil).find_each do |report|
        report.update!(closed_at: @now, closed_by: current_staff.user_id)
        audit(report, "closed", entity_id: @case.id,
          before: { "closed_at" => nil }, after: { "closed_at" => @now })
        queue(report, said)
      end
    end

    def queue(report, said)
      conversation = IntakeConversation.find_by(report_id: report.id, closed_at: nil)
      return if conversation.nil?

      IntakeOutbox.create!(conversation_id: conversation.id, kind: "outcome", body: said,
        requested_by: current_staff.user_id)
    end

    def refusal(kase)
      return "case #{kase.id} was already resolved" if kase.resolved?

      not_yours(kase)
    end

    def refuse(message)
      redirect_to fd_case_path(@case), alert: message
    end
  end
end
