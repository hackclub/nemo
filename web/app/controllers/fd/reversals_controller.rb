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

      target_action = Action.find_by(id: params[:action_id], case_id: kase.id, reversed_at: nil)
      if target_action&.reversal_reactivates? && !current_account.may?("member.deactivate")
        return deny!("member.deactivate", kase)
      end

      reason = params[:reversal_reason].to_s.strip

      error = validation_error(reason)
      if error
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
        lifted = lift_linked_guard(action, reason)
      end

      if reversed
        redirect_to fd_case_path(kase, tab: "actions"), notice: reversed_notice(lifted)
      else
        redirect_to fd_case_path(kase, tab: "actions"),
          alert: "Action not found or already reversed"
      end
    end

    private

    def lift_linked_guard(action, reason)
      guard = action.guard
      return nil if guard.nil? || !MemberGuard::ACTIVE_STATES.include?(guard.state)
      return nil if Action.live.exists?(guard_id: guard.id)

      previous_state = guard.state
      lift_reason = "Action reversed: #{reason}"
      return nil unless guard.lift!(by: current_account.user_id, reason: lift_reason)

      audit(guard, "lifted", before: { "state" => previous_state },
        after: { "state" => guard.state, "lift_reason" => lift_reason })
      guard
    end

    def reversed_notice(guard)
      return "Action reversed" if guard.nil?
      return "Action reversed · reactivation queued" if guard.deactivation?

      "Action reversed · #{guard_label_text(guard)} lifted"
    end

    def guard_label_text(guard) = FdHelper::ACTION_LABELS.fetch(guard.kind, guard.kind).downcase

    def validation_error(reason)
      if reason.blank?
        return field_error!(:reversal_reason, "Enter a reason")
      end
      if reason.length > MAX_REASON
        return field_error!(:reversal_reason,
          "Keep it under #{MAX_REASON} characters", reason)
      end

      nil
    end
  end
end
