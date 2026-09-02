module Fd
  class SupersessionsController < BaseController
    before_action { needs(:decisions) }

    include DecisionWords

    permit "decision.retire"

    def create
      old = Decision.find(params[:decision_id])
      problem = missing_words
      return redirect_to(fd_decision_path(old), alert: problem) if problem

      fresh = nil
      writing do
        fresh = Decision.create!(written.merge(proposed_by: current_account.user_id,
          state: "settled", settled_by: current_account.user_id, settled_at: Time.current))
        audit(fresh, "proposed")
        audit(fresh, "settled")
        old.supersede!(fresh, by: current_account.user_id)
        audit(old, "superseded", after: { "replaced_by_id" => fresh.id })
      end

      redirect_to fd_decision_path(fresh), notice: "replaces #{old.title}"
    rescue Decision::NotAllowed => e
      redirect_to fd_decision_path(old), alert: e.message
    rescue ActiveRecord::RecordNotUnique
      redirect_to fd_decision_path(old), alert: "there is already a decision called that"
    end
  end
end
