module Fd
  class RetirementsController < BaseController
    before_action { needs(:decisions) }

    permit "decision.retire"

    def create
      decision = Decision.find(params[:decision_id])

      writing do
        decision.retire!(by: current_account.user_id)
        audit(decision, "superseded", after: { "state" => "superseded",
          "replaced_by_id" => nil })
      end

      redirect_to fd_decision_path(decision), notice: "retired"
    rescue Decision::NotAllowed => e
      redirect_to fd_decision_path(decision), alert: e.message
    end
  end
end
