module Fd
  class CaseDecisionsController < BaseController
    def create
      kase = Case.find(params[:case_id])
      decision = Decision.find_by(id: params[:decision_id])
      return redirect_to(fd_case_path(kase), alert: refusal(kase)) if refusal(kase)
      return redirect_to(fd_case_path(kase), alert: "pick a decision") if decision.nil?

      writing do
        kase.update!(followed_decision_id: decision.id)
        audit(kase, "followed", after: { "followed_decision_id" => decision.id })
      end

      redirect_to fd_case_path(kase), notice: linked_notice(decision)
    end

    def destroy
      kase = Case.find(params[:case_id])
      return redirect_to(fd_case_path(kase), alert: refusal(kase)) if refusal(kase)
      return redirect_to(fd_case_path(kase),
        alert: "this case follows no decision") if kase.followed_decision_id.nil?

      writing do
        was = kase.followed_decision_id
        kase.update!(followed_decision_id: nil)
        audit(kase, "unfollowed", before: { "followed_decision_id" => was }, after: nil)
      end

      redirect_to fd_case_path(kase), notice: "no longer recorded as following a decision"
    end

    private

    def linked_notice(decision)
      return "recorded as following #{decision.title}" if decision.settled?

      "recorded behind the #{decision.title} proposal"
    end

    def refusal(kase)
      not_yours(kase)
    end
  end
end
