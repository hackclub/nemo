module Fd
  class ActionsController < BaseController
    include LogsActions
    include ClosesReports

    permit "case.act", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      lock = Action.from_thread_lock?(type_key) ? thread_lock : nil
      guard = lock ? nil : existing_guard

      error = guard ? existing_guard_error(kase, guard) : action_error(kase)
      error ||= "Not permitted to resolve cases" if resolve_case? && !current_account.may?("case.resolve", kase)
      if error
        return redirect_to(fd_case_path(kase, do: "action"),
          alert: (error unless flash[:field_error]))
      end

      subject_added = false
      thread_attached = lock&.orphaned?
      echo = nil
      resolved = false
      writing do
        subject_added = add_target_subject(kase) unless lock
        if guard
          attach_existing_guard(kase, guard)
        elsif lock
          audit(log_thread_lock(kase, lock), "performed")
        else
          action = log_action(kase, Time.current)
          audit(action, "performed")
          enforce(kase, action)
          echo = ActionEcho.write!(kase, action, by: current_account.user_id)
        end
        if resolve_case?
          resolved = resolve_case(kase)
          close_reports(kase, Time.current) if resolved && notify_reporter?
        end
      end
      SlackPost.post_to_thread(echo) if echo&.mirrored_as == "user"

      redirect_to fd_case_path(kase, tab: "actions"),
        notice: notice_for(kase, guard: guard, lock: lock, thread_attached: thread_attached,
          subject_added: subject_added, resolved: resolved)
    end

    def update
      kase = Case.find(params[:case_id])
      action = Action.find_by(id: params[:id], case_id: kase.family_ids)
      return redirect_to(fd_case_path(kase, tab: "actions"), alert: "Action not found") if action.nil?

      error = edit_error(action)
      if error
        return redirect_to(fd_case_path(kase, tab: "actions", do: "edit-action-#{action.id}"),
          alert: (error unless flash[:field_error]))
      end

      action.assign_attributes(reason: params[:reason].to_s.strip.presence,
        solution: params[:solution].to_s.strip.presence,
        category_key: params[:category_key].to_s.presence)
      return redirect_to(fd_case_path(kase, tab: "actions"), notice: "No changes") unless action.changed?

      writing do
        action.save!
        audit(action, "edited")
      end
      redirect_to fd_case_path(kase, tab: "actions"), notice: "Action updated"
    end

    private

    def edit_error(action)
      if params[:reason].to_s.strip.blank? && !action.from_thread_lock? &&
          InfractionCategory.needs_reason?(params[:category_key])
        return field_error!(:edit_reason, "Enter a reason", params[:reason])
      end

      category_key = params[:category_key].to_s
      if category_key.present? && category_key != action.category_key &&
          !InfractionCategory.active_key?(category_key)
        return "Select a category"
      end

      nil
    end

    def notice_for(kase, guard:, lock:, thread_attached:, subject_added:, resolved:)
      message = if guard
        attached_notice(kase, guard)
      elsif lock
        locked_notice(kase, thread_attached)
      else
        logged_notice(kase, subject_added)
      end
      resolved ? "#{message} · case resolved" : message
    end

    def resolve_case(kase)
      return false unless kase.mark_resolved!("action_taken", at: Time.current)

      kase.reload
      audit(kase, "resolved",
        before: { "resolved_at" => nil, "resolution" => nil },
        after: { "resolved_at" => kase.resolved_at, "resolution" => kase.resolution,
                 "duplicate_of" => kase.duplicate_of, "member_note" => kase.member_note })
      true
    end

    def add_target_subject(kase)
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
      "#{guard_label_text(guard).upcase_first} attached to case #{kase.id}"
    end

    def locked_notice(kase, thread_attached)
      message = "Thread lock logged on case #{kase.id}"
      thread_attached ? "#{message} · thread attached" : message
    end

    def logged_notice(kase, subject_added)
      message = "#{type_name} logged on case #{kase.id}"
      subject_added ? "#{message} · @#{target_user_id} added to case" : message
    end
  end
end
