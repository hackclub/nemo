module Fd
  class SettlementsController < BaseController
    before_action { needs(:decisions) }

    permit "decision.settle"

    def create
      decision = Decision.find(params[:decision_id])

      writing do
        decision.settle!(by: current_staff.user_id)
        audit(decision, "settled")
      end

      redirect_to fd_decision_path(decision), notice: "settled"
    rescue Decision::NotAllowed => e
      redirect_to fd_decision_path(decision), alert: e.message
    end
  end
end
