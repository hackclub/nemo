module Fd
  class ActionsController < BaseController
    include LogsActions

    permit "case.act", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      lock = Action.from_thread_lock?(type_key) ? thread_lock : nil
      held = lock ? nil : standing_guard

      problem = held ? standing_objection(kase, held) : action_objection(kase)
      if problem
        return redirect_to(fd_case_path(kase, do: "action"),
          alert: (problem unless flash[:wrong]))
      end

      named = false
      adopted = lock&.orphaned?
      writing do
        named = name_a_subject(kase) unless lock
        if held
          attach_standing(kase, held)
        elsif lock
          audit(log_thread_lock(kase, lock), "performed")
        else
          action = log_action(kase, Time.current)
          audit(action, "performed")
          enforce(kase, action)
        end
      end

      redirect_to fd_case_path(kase, tab: "actions"),
        notice: notice_for(kase, held: held, lock: lock, adopted: adopted, named: named)
    end

    private

    def notice_for(kase, held:, lock:, adopted:, named:)
      return attached_notice(kase, held) if held
      return locked_notice(kase, adopted) if lock

      logged_notice(kase, named)
    end

    def name_a_subject(kase)
      return false if target_user_id.blank?
      return false if kase.subject_user_ids.include?(target_user_id)

      ActiveRecord::Base.transaction(requires_new: true) do
        audit(kase.add_subject!(target_user_id), "attached", entity_id: kase.id)
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def attached_notice(kase, guard)
      "the #{guard_said(guard)} already standing on @#{guard.subject_id} " \
        "is now on case #{kase.id}"
    end

    def locked_notice(kase, adopted)
      said = "thread lock logged on case #{kase.id}"
      adopted ? "#{said}, and the thread is now on this case" : said
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
