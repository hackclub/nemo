module Fd
  class ReversalsController < BaseController
    MAX_REASON = 500

    permit "case.reverse", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      if params[:action_id].blank?
        return redirect_to(fd_case_path(kase, tab: "actions"),
          alert: "Select an action to reverse")
      end

      reason = params[:reversal_reason].to_s.strip

      problem = objection(reason)
      if problem
        return redirect_to(fd_case_path(kase, tab: "actions", do: "reverse-#{params[:action_id]}"))
      end

      now = Time.current
      reversed = false
      lifted = nil

      writing do
        rows = Action.where(id: params[:action_id], case_id: kase.id, reversed_at: nil)
          .update_all(reversed_at: now, reversed_by: current_account.user_id,
            reversal_reason: reason)
        next if rows.zero?

        reversed = true
        action = Action.find(params[:action_id])
        audit(action, "reversed",
          before: { "reversed_at" => nil },
          after: {
            "reversed_at" => action.reversed_at,
            "reversed_by" => action.reversed_by,
            "reason" => reason
          })
        lifted = lift_what_it_held(action, reason)
      end

      if reversed
        redirect_to fd_case_path(kase, tab: "actions"), notice: reversed_notice(lifted)
      else
        redirect_to fd_case_path(kase, tab: "actions"),
          alert: "That action is not on this case, or was already reversed"
      end
    end

    private

    def lift_what_it_held(action, reason)
      guard = action.guard
      return nil if guard.nil? || !MemberGuard::STILL_ON.include?(guard.state)
      return nil if Action.live.exists?(guard_id: guard.id)

      was = guard.state
      lift_reason = "the action was reversed: #{reason}"
      return nil unless guard.lift!(by: current_account.user_id, reason: lift_reason)

      audit(guard, "lifted", before: { "state" => was },
        after: { "state" => guard.state, "lift_reason" => lift_reason })
      guard
    end

    def reversed_notice(guard)
      return "action reversed, and the record keeps both" if guard.nil?

      "action reversed, and the #{guard_label_text(guard)} it held is lifted"
    end

    def guard_label_text(guard) = FdHelper::ACTION_LABELS.fetch(guard.kind, guard.kind).downcase

    def objection(reason)
      if reason.blank?
        return wrong!(:reversal_reason, "Say why it is being reversed. It goes on the record.")
      end
      if reason.length > MAX_REASON
        return wrong!(:reversal_reason,
          "Keep it under #{MAX_REASON} characters. That one is #{reason.length}.", reason)
      end

      nil
    end
  end
end
