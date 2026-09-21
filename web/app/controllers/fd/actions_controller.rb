module Fd
  class ActionsController < BaseController
    include LogsActions

    permit "case.act", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])

      problem = action_objection
      if problem
        return redirect_to(fd_case_path(kase, do: "action"),
          alert: (problem unless flash[:wrong]))
      end

      named = false
      writing do
        named = name_a_subject(kase)
        audit(log_action(kase, Time.current), "performed")
      end

      redirect_to fd_case_path(kase, tab: "actions"), notice: logged_notice(kase, named)
    end

    private

    def name_a_subject(kase)
      return false if kase.subject_user_ids.include?(target_user_id)

      ActiveRecord::Base.transaction(requires_new: true) do
        audit(kase.add_subject!(target_user_id), "attached", entity_id: kase.id)
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def logged_notice(kase, named)
      said = if kase.resolved?
        "#{type_name.downcase} logged on case #{kase.id}"
      else
        "#{type_name.downcase} logged, case #{kase.id} stays open"
      end
      named ? "#{said}, and the case is now also about @#{target_user_id}" : said
    end
  end
end
