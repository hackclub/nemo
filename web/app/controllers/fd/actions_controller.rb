module Fd
  class ActionsController < BaseController
    include LogsActions

    permit "case.act", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])

      problem = action_objection || not_yours(kase)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        audit(log_action(kase, Time.current), "performed")
      end

      redirect_to fd_case_path(kase), notice: logged_notice(kase)
    end

    private

    def logged_notice(kase)
      return "#{type_name.downcase} logged on case #{kase.id}" if kase.resolved?

      "#{type_name.downcase} logged, case #{kase.id} stays open"
    end
  end
end
