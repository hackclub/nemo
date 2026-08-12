module Fd
  class ResolutionsController < BaseController
    NEEDS_EXPIRY = %w[shush temp_ban channel_ban].freeze
    NEEDS_CHANNEL = %w[channel_ban].freeze
    TAKES_CHANNEL = %w[channel_ban locked_thread].freeze

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
        @case.reload
        audit(@case, "resolved",
          before: { "resolved_at" => nil, "resolution" => nil },
          after: {
            "resolved_at" => @case.resolved_at,
            "resolution" => resolution,
            "duplicate_of" => @case.duplicate_of,
            "member_note" => @case.member_note,
          })
      end

      if settled
        redirect_to fd_case_path(@case), notice: "case #{@case.id} resolved"
      else
        refuse(refusal(@case.reload))
      end
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
      return report_objection if params[:outcome] == "report"
      return duplicate_objection if resolution == "duplicate"

      nil
    end

    def report_objection
      return "pick what was done" unless FdHelper::ACTION_LABELS.key?(params[:type_key].to_s)
      return "say who it was directed at" if params[:target_user_id].blank?
      if NEEDS_EXPIRY.include?(params[:type_key]) && params[:expires_on].blank?
        return "#{type_name.downcase} needs a date it runs until"
      end
      if NEEDS_CHANNEL.include?(params[:type_key]) && params[:channel_id].blank?
        return "#{type_name.downcase} needs a channel"
      end

      nil
    end

    def type_name
      FdHelper::ACTION_LABELS.fetch(params[:type_key].to_s, params[:type_key].to_s)
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
        .where(claimed_by: [nil, current_staff.user_id])
        .update_all(
          resolved_at: @now,
          resolution: resolution,
          member_note: (params[:member_note].presence unless resolution == "duplicate"),
          duplicate_of: (params[:duplicate_of] if resolution == "duplicate"),
          updated_at: @now
        ).positive?
    end

    def file_report
      action = Action.create!(
        case_id: @case.id,
        type_key: params[:type_key],
        target_user_id: params[:target_user_id].strip,
        decided_by: current_staff.user_id,
        performed_by: current_staff.user_id,
        performed_at: @now,
        source_app: Audit::SOURCE_APP,
        expires_at: expiry_for(params[:type_key]),
        details: channel_for(params[:type_key])
      )
      audit(action, "performed")
    end

    def expiry_for(type_key)
      return nil unless NEEDS_EXPIRY.include?(type_key)

      params[:expires_on].presence&.to_date&.end_of_day
    end

    def channel_for(type_key)
      return {} unless TAKES_CHANNEL.include?(type_key)
      return {} if params[:channel_id].blank?

      { "channel_id" => params[:channel_id].strip }
    end

    def refusal(kase)
      return "case #{kase.id} was already resolved" if kase.resolved?

      "case #{kase.id} is assigned to @#{kase.claimed_by}, not to you"
    end

    def refuse(message)
      redirect_to fd_case_path(@case), alert: message
    end
  end
end
