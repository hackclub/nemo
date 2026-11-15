module Fd
  module ReactivatesMembers
    private

    def standing_deactivation(subject_id)
      MemberGuard.active.for_subject(subject_id).find_by(kind: MemberGuard::DEACTIVATION)
    end

    OUTSIDE_NEMO = "Deactivated outside Nemo".freeze

    def record_deactivation(subject_id)
      return nil unless MemberAccount.find_by(user_id: subject_id)&.deactivated

      ban = Action.running_bans_on(subject_id).order(performed_at: :desc, id: :desc).first
      guard = MemberGuard.record_deactivation!(subject_id: subject_id,
        by: ban&.performed_by || current_account.user_id,
        reason: ban&.reason.presence || (ban && Action::LABELS[ban.type_key]) || OUTSIDE_NEMO,
        opened_at: ban&.performed_at, case_id: ban&.case_id)
      audit(guard, "recorded") if guard
      guard
    end

    def lift_deactivation(guard, reason)
      previous_state = guard.state
      return nil unless guard.lift!(by: current_account.user_id, reason: reason)

      audit(guard, "lifted", before: { "state" => previous_state },
        after: { "state" => guard.state, "lift_reason" => reason })
      guard
    end

    def end_bans(subject_id, reason)
      now = Time.current
      Action.running_bans_on(subject_id, now).lock.order(:id).to_a.each do |action|
        before = action.expires_at
        action.update_columns(expires_at: now)
        audit(action, "ended", before: { "expires_at" => before },
          after: { "expires_at" => now, "reason" => reason })
      end
    end

    def reactivation_notice(guard, ended, name)
      message = guard.nil? || guard.lifting? ? "Reactivation queued for #{name}" : "Deactivation lifted on #{name}"
      ended.any? ? "#{message} · #{ActionController::Base.helpers.pluralize(ended.size, 'ban')} ended" : message
    end
  end
end
