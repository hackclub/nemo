module Fd
  module LogsActions
    NEEDS_EXPIRY = Action::NEEDS_EXPIRY
    TAKES_EXPIRY = Action::TAKES_EXPIRY
    NEEDS_CHANNEL = Action::NEEDS_CHANNEL
    TAKES_CHANNEL = Action::TAKES_CHANNEL
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    private

    def target_user_id
      params[:target_user_id].to_s.strip
    end

    def channel_id
      params[:channel_id].to_s.strip
    end

    def type_key
      params[:type_key].to_s
    end

    def type_name
      FdHelper::ACTION_LABELS.fetch(type_key, type_key)
    end

    def deactivates?(key = type_key) = Action.deactivates?(key)

    def may_deactivate? = current_account&.may?("member.deactivate")

    def action_error(kase)
      return "Select an action" unless FdHelper::ACTION_LABELS.key?(type_key)
      return thread_lock_error(kase) if Action.from_thread_lock?(type_key)
      return "Select a target" if target_user_id.blank?
      return "#{target_user_id} is not a member id" unless target_user_id.match?(MEMBER_ID)
      return "Not permitted to log #{type_name}" if deactivates? && !may_deactivate?
      if NEEDS_EXPIRY.include?(type_key) && params[:expires_on].blank?
        return "#{type_name} needs an end date"
      end
      return expiry_error if expiry_error
      if NEEDS_CHANNEL.include?(type_key) && channel_id.blank?
        return "#{type_name} needs a channel"
      end
      if channel_id.present? && !channel_id.match?(SlackLink::CHANNEL)
        return "#{channel_id} is not a channel id"
      end
      if params[:reason].to_s.strip.blank? && InfractionCategory.needs_reason?(selected_category(kase))
        return field_error!(:reason, "Enter a reason", params[:reason])
      end

      nil
    end

    def log_action(kase, performed_at)
      Action.create!(
        case_id: kase.id,
        type_key: type_key,
        target_user_id: target_user_id,
        decided_by: current_account.user_id,
        performed_by: current_account.user_id,
        performed_at: performed_at,
        source_app: Audit::SOURCE_APP,
        expires_at: expiry,
        reason: params[:reason].to_s.strip.presence,
        solution: params[:solution].to_s.strip.presence,
        resolved_by: resolver_ids,
        category_key: selected_category(kase),
        details: channel
      )
    end

    def resolver_ids
      ids = Array(params[:resolved_by]).map { |user_id| user_id.to_s.strip }
        .select { |user_id| user_id.match?(MEMBER_ID) }.uniq
      ids.presence || [current_account.user_id]
    end

    def resolve_case? = params[:resolve_case] == "1"

    def thread_lock_error(kase)
      family = kase.family_ids
      return "Select a thread lock" if thread_lock.nil?
      return "Thread lock already on this case" if thread_lock.on_case?(family)
      if Action.live.exists?(case_id: family, thread_guard_id: thread_lock.id)
        return "Thread lock already logged on this case"
      end

      nil
    end

    def thread_lock
      return @thread_lock if defined?(@thread_lock)

      guard_id = params[:thread_guard_id].to_s.presence
      @thread_lock = guard_id && ThreadGuard.active.locks.find_by(id: guard_id)
    end

    def log_thread_lock(kase, guard)
      previous_case_id = guard.case_id
      if guard.orphaned? && guard.attach_to!(kase.id)
        audit(guard, "attached", before: { "case_id" => previous_case_id },
          after: { "case_id" => kase.id })
      end

      Action.create!(
        case_id: kase.id, type_key: type_key, target_user_id: nil,
        decided_by: current_account.user_id, performed_by: current_account.user_id,
        performed_at: Time.current, source_app: Audit::SOURCE_APP,
        expires_at: guard.expires_at, reason: guard.reason,
        category_key: selected_category(kase), thread_guard_id: guard.id,
        details: { "channel_id" => guard.channel_id, "thread_ts" => guard.thread_ts }
      )
    end

    def guard_label_text(guard) = FdHelper::ACTION_LABELS.fetch(guard.kind, guard.kind).downcase

    def existing_guard_error(kase, guard)
      family = kase.family_ids
      label = guard_label_text(guard)
      return "#{label.upcase_first} already on this case" if guard.on_case?(family)
      if Action.live.exists?(case_id: family, guard_id: guard.id)
        return "#{label.upcase_first} already logged on this case"
      end

      nil
    end

    def existing_guard
      guard_id = params[:standing_guard_id].to_s.presence
      return nil if guard_id.nil?

      MemberGuard.active.for_subject(target_user_id).find_by(id: guard_id)
    end

    def guard_channel(type_key)
      return nil unless Action.guard_scope(type_key) == "channel"

      channel_id.presence
    end

    def attach_existing_guard(kase, guard)
      previous_case_id = guard.case_id
      if guard.orphaned? && guard.attach_to!(kase.id)
        audit(guard, "attached", before: { "case_id" => previous_case_id },
          after: { "case_id" => kase.id })
      end

      action = Action.create!(
        case_id: kase.id, type_key: guard.kind, target_user_id: guard.subject_id,
        decided_by: current_account.user_id, performed_by: current_account.user_id,
        performed_at: Time.current, source_app: Audit::SOURCE_APP,
        expires_at: guard.expires_at, reason: guard.reason,
        category_key: selected_category(kase), guard_id: guard.id,
        details: guard.channel_id ? { "channel_id" => guard.channel_id } : {}
      )
      audit(action, "performed")
      action
    end

    def enforce(kase, action)
      return nil unless Action.enforceable?(action.type_key)

      guard = MemberGuard.open!(
        kind: Action.guard_kind(action.type_key), subject_id: action.target_user_id,
        channel_id: guard_channel(action.type_key), case_id: kase.id,
        by: current_account.user_id, reason: guard_reason(action), expires_at: action.expires_at
      )
      return nil if guard.nil?

      audit(guard, "opened")
      action.update!(guard_id: guard.id)
      guard
    end

    def guard_reason(action)
      action.reason.presence || InfractionCategory.label(action.category_key)
    end

    def selected_category(kase)
      requested_category = params[:category_key].to_s
      return requested_category if InfractionCategory.active_key?(requested_category)

      kase.category_key
    end

    def end_time
      @end_time ||= if TAKES_EXPIRY.include?(type_key)
        EndTime.read(params[:expires_on], params[:expires_time])
      else
        [nil, nil]
      end
    end

    def expiry = end_time.first

    def expiry_error = end_time.last

    def channel
      return {} unless TAKES_CHANNEL.include?(type_key)
      return {} if channel_id.blank?

      { "channel_id" => channel_id }
    end
  end
end
