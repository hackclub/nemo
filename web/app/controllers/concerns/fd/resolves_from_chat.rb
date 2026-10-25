module Fd
  module ResolvesFromChat
    include ClosesReports

    private

    def resolve_from_chat(kase)
      denied_reason = Access.why_not(current_account, "case.reply", kase) ||
        Access.why_not(current_account, "case.resolve", kase)
      return redirect_to(fd_case_path(kase, tab: "report"), alert: denied_reason) if denied_reason

      now = Time.current
      resolution = Action.where(case_id: kase.family_ids).live.any? ? "action_taken" : "no_action"
      resolved = false
      writing do
        next unless kase.mark_resolved!(resolution, at: now)

        resolved = true
        close_reports(kase, now)
        Case.where(id: kase.id).update_all(resolution_echo_by: current_account.user_id)
        kase.reload
        audit(kase, "resolved",
          before: { "resolved_at" => nil, "resolution" => nil },
          after: { "resolved_at" => kase.resolved_at, "resolution" => resolution,
                   "duplicate_of" => kase.duplicate_of, "member_note" => kase.member_note })
      end

      if resolved
        redirect_to fd_case_path(kase, tab: "report"), notice: "Case #{kase.id} resolved"
      else
        redirect_to fd_case_path(kase, tab: "report"), alert: "Case #{kase.id} was already resolved"
      end
    end
  end
end
