module Fd
  class ClaimsController < BaseController
    def create
      kase = Case.find(params[:case_id])
      now = Time.current
      taken = false

      writing do
        rows = Case.where(id: kase.id, claimed_at: nil, resolved_at: nil)
          .update_all(claimed_by: current_staff.user_id, claimed_at: now, updated_at: now)
        next if rows.zero?

        taken = true
        kase.reload
        audit(kase, "claimed",
          before: { "claimed_by" => nil, "claimed_at" => nil },
          after: { "claimed_by" => kase.claimed_by, "claimed_at" => kase.claimed_at })
      end

      if taken
        redirect_to fd_case_path(kase), notice: "case #{kase.id} is yours"
      else
        redirect_to fd_case_path(kase), alert: claim_refusal(kase.reload)
      end
    end

    def destroy
      kase = Case.find(params[:case_id])
      released = false

      writing do
        rows = Case.where(id: kase.id, claimed_by: current_staff.user_id)
          .update_all(claimed_by: nil, claimed_at: nil, updated_at: Time.current)
        next if rows.zero?

        released = true
        audit(kase, "unclaimed",
          before: { "claimed_by" => current_staff.user_id },
          after: { "claimed_by" => nil })
      end

      if released
        redirect_to fd_case_path(kase), notice: "case #{kase.id} is back in the queue"
      else
        redirect_to fd_case_path(kase), alert: release_refusal(kase.reload)
      end
    end

    private

    def claim_refusal(kase)
      return "case #{kase.id} is already resolved" if kase.resolved?
      return "case #{kase.id} is already yours" if kase.claimed_by == current_staff.user_id

      "case #{kase.id} was claimed by @#{kase.claimed_by} a moment ago"
    end

    def release_refusal(kase)
      return "case #{kase.id} is not assigned to anybody" unless kase.claimed?

      "case #{kase.id} is assigned to @#{kase.claimed_by}, not to you"
    end
  end
end
