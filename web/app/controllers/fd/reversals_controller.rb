module Fd
  class ReversalsController < BaseController
    MAX_REASON = 500

    permit "case.reverse", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      reason = params[:reversal_reason].to_s.strip

      problem = objection(kase, reason)
      if problem
        return redirect_to(fd_case_path(kase, tab: "actions", do: "reverse-#{params[:action_id]}"))
      end

      now = Time.current
      reversed = false

      writing do
        rows = Action.where(id: params[:action_id], case_id: kase.id, reversed_at: nil)
          .update_all(reversed_at: now, reversed_by: current_staff.user_id,
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
      end

      if reversed
        redirect_to fd_case_path(kase, tab: "actions"),
          notice: "action reversed, and the record keeps both"
      else
        redirect_to fd_case_path(kase, tab: "actions"),
          alert: "that action is not on this case, or was reversed already"
      end
    end

    private

    def objection(kase, reason)
      return "pick the action to reverse" if params[:action_id].blank?

      if reason.blank?
        return wrong!(:reversal_reason, "Say why it is being reversed. It goes on the record.")
      end
      if reason.length > MAX_REASON
        return wrong!(:reversal_reason,
          "Keep it under #{MAX_REASON} characters. That one is #{reason.length}.", reason)
      end

      refusal = not_yours(kase)
      refusal && wrong!(:reversal_reason, refusal, reason)
    end
  end
end
