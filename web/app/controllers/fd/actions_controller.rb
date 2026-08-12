module Fd
  class ActionsController < BaseController
    include LogsActions

    def create
      kase = Case.find(params[:case_id])

      problem = action_objection || claim_objection(kase)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        audit(log_action(kase, Time.current), "performed")
      end

      redirect_to fd_case_path(kase), notice: logged_notice(kase)
    end

    private

    def claim_objection(kase)
      return nil if kase.claimed_by.nil? || kase.claimed_by == current_staff.user_id

      "case #{kase.id} is assigned to @#{kase.claimed_by}, not to you"
    end

    def logged_notice(kase)
      return "#{type_name.downcase} logged on case #{kase.id}" if kase.resolved?

      "#{type_name.downcase} logged, case #{kase.id} stays open"
    end
  end
end
