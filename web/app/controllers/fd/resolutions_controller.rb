module Fd
  class ResolutionsController < BaseController
    include LogsActions

    def create
      @case = Case.find(params[:case_id])
      @now = Time.current

      resolution = resolution_for(params[:outcome].to_s)
      return refuse("say how this case ended") if resolution.nil?

      problem = objection(resolution)
      return refuse(problem) if problem

      settled = false
      writing do
        next unless mark_resolved(resolution)

        settled = true
        file_report if params[:outcome] == "report"
        close_reports
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

      was = { "resolved_at" => @case.resolved_at, "resolution" => @case.resolution,
              "duplicate_of" => @case.duplicate_of,
              "followed_decision_id" => @case.followed_decision_id }

      writing do
        @case.update!(resolved_at: nil, resolution: nil, duplicate_of: nil,
          followed_decision_id: nil, updated_at: @now)
        audit(@case, "reopened", before: was,
          after: { "resolved_at" => nil, "resolution" => nil, "duplicate_of" => nil,
                   "followed_decision_id" => nil })
      end

      redirect_to fd_case_path(@case), notice: "case #{@case.id} is open again"
    end

    private

    def resolution_for(outcome)
      case outcome
      when "report" then "action_taken"
      when "duplicate" then "duplicate"
      when "close"
        reason = params[:close_reason].to_s
        Case::CLOSE_REASONS.include?(reason) ? reason : nil
      end
    end

    def objection(resolution)
      return action_objection if params[:outcome] == "report"
      return duplicate_objection if resolution == "duplicate"

      nil
    end

    def duplicate_objection
      other = params[:duplicate_of].to_s
      return "say which case this duplicates" if other.blank?
      return "a case cannot duplicate itself" if other.to_i == @case.id
      return "case #{other} does not exist" unless Case.exists?(id: other)

      nil
    end

    def mark_resolved(resolution)
      Case.where(id: @case.id, resolved_at: nil)
        .free_or_assigned_to(current_staff.user_id)
        .update_all(
          resolved_at: @now,
          resolution: resolution,
          member_note: (params[:member_note].presence unless resolution == "duplicate"),
          duplicate_of: (params[:duplicate_of] if resolution == "duplicate"),
          updated_at: @now
        ).positive?
    end

    def file_report
      audit(log_action(@case, @now), "performed")
    end

    def close_reports
      @case.reports.where(closed_at: nil).find_each do |report|
        report.update!(closed_at: @now, closed_by: current_staff.user_id)
        audit(report, "closed", entity_id: @case.id,
          before: { "closed_at" => nil }, after: { "closed_at" => @now })
      end
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
