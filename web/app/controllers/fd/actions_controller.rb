module Fd
  class ActionsController < BaseController
    include LogsActions

    permit "case.act", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])

      problem = action_objection || not_yours(kase)
      if problem
        return redirect_to(fd_case_path(kase, do: "action"),
          alert: (problem unless flash[:wrong]))
      end

      writing do
        audit(log_action(kase, Time.current), "performed")
      end

      redirect_to fd_case_path(kase, tab: "actions"), notice: logged_notice(kase)
    end

    private

    def logged_notice(kase)
      return "#{type_name.downcase} logged on case #{kase.id}" if kase.resolved?

      "#{type_name.downcase} logged, case #{kase.id} stays open"
    end
  end
end
