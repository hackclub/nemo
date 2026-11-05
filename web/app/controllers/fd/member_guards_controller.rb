module Fd
  class MemberGuardsController < BaseController
    permit "member.guard"

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def create
      return deny!("member.deactivate") if deactivating?(kind)
      return deny!("member.purge") if purging? && !current_account&.may?("member.purge")

      error = guard_error
      if error
        return redirect_to(fd_member_path(subject_id, do: kind == MemberGuard::DEACTIVATION ? "deactivate" : "guard"),
          alert: (error unless flash[:field_error]))
      end

      guard = nil
      queued = nil
      writing do
        guard = open_guard
        queued = queue_purge(guard) if guard && purging?
      end

      if guard.nil?
        return redirect_to fd_member_path(subject_id),
          alert: "#{display_name(subject_id)} already has a #{"scheduled " if starts_at}#{label(kind)}"
      end

      redirect_to fd_member_path(subject_id),
        notice: "#{created_notice(guard)}#{purge_note(queued)}"
    end

    def update
      guard = MemberGuard.active_or_scheduled.find(params[:id])
      return deny!("member.deactivate", guard) if deactivating?(guard.kind)
      return redirect_to(fd_member_path(guard.subject_id), alert: "Set in Firehose") if guard.firehose?
      return reschedule(guard) if guard.scheduled?

      error = expiry_error || ("Enter an end date" if expiry.nil?) || StartTime.error(guard.starts_at, expiry)
      return redirect_to(fd_member_path(guard.subject_id), alert: error) if error

      previous_expiry = guard.expires_at
      writing do
        guard.set_expiry!(expiry)
        audit(guard, "extended", before: { "expires_at" => previous_expiry },
          after: { "expires_at" => expiry })
      end

      redirect_to fd_member_path(guard.subject_id),
        notice: "#{label(guard.kind).upcase_first} extended · ends #{ShortDate.ending(expiry)}"
    end

    def destroy
      guard = MemberGuard.active_or_scheduled.find(params[:id])
      return deny!("member.deactivate", guard) if deactivating?(guard.kind)
      return redirect_to(fd_member_path(guard.subject_id), alert: "Set in Firehose") if guard.firehose?
      return cancel(guard) if guard.scheduled?

      previous_state = guard.state
      writing do
        guard.lift!(by: current_account.user_id, reason: lift_reason)
        audit(guard, "lifted", before: { "state" => previous_state },
          after: { "state" => guard.state, "lift_reason" => lift_reason })
      end

      redirect_to fd_member_path(guard.subject_id),
        notice: "#{label(guard.kind).upcase_first} lifted on #{display_name(guard.subject_id)}"
    end

    private

    def reschedule(guard)
      new_start, start_error = StartTime.read(params[:starts_on], params[:starts_time])
      error = start_error || ("Enter a start date" if new_start.nil?) || expiry_error ||
        StartTime.error(new_start, expiry)
      return redirect_to(fd_member_path(guard.subject_id), alert: error) if error

      before = { "starts_at" => guard.starts_at, "expires_at" => guard.expires_at }
      writing do
        guard.reschedule!(starts_at: new_start, expires_at: expiry)
        audit(guard, "edited", before: before, after: { "starts_at" => new_start, "expires_at" => expiry })
      end

      redirect_to fd_member_path(guard.subject_id),
        notice: "Deactivation rescheduled · starts #{ShortDate.starting(new_start)}"
    end

    def cancel(guard)
      reason = params[:cancel_reason].to_s.strip.presence
      writing do
        guard.cancel!(by: current_account.user_id, reason: reason)
        audit(guard, "cancelled", before: { "state" => MemberGuard::SCHEDULED },
          after: { "state" => guard.state, "cancel_reason" => reason })
      end

      redirect_to fd_member_path(guard.subject_id),
        notice: "Scheduled deactivation cancelled on #{display_name(guard.subject_id)}"
    end

    def created_notice(guard)
      unless guard.scheduled?
        return "#{label(guard.kind).upcase_first} applied to #{display_name(subject_id)}"
      end

      "Deactivation scheduled for #{display_name(subject_id)} · starts #{ShortDate.starting(guard.starts_at)}"
    end

    def start_time
      return [nil, nil] unless kind == MemberGuard::DEACTIVATION

      @start_time ||= StartTime.read(params[:starts_on], params[:starts_time])
    end

    def starts_at = start_time.first

    def subject_id = params[:member_id].to_s.upcase

    def kind = params[:kind].to_s

    def may_deactivate? = current_account&.may?("member.deactivate")

    def purging? = kind == MemberGuard::DEACTIVATION && params[:purge_messages] == "1"

    def queue_purge(guard)
      purge = ChannelPurge.transaction(requires_new: true) do
        ChannelPurge.create!(member_id: subject_id, reason: guard.reason, source: "deactivation",
          guard_id: guard.id, asked_by: current_account.user_id)
      end
      audit(purge, "queued", subject_user_id: subject_id,
        after: { "member_id" => subject_id, "guard_id" => guard.id, "source" => "deactivation" })
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def purge_note(queued)
      return "" if queued.nil?
      return " · Message purge already running" unless queued

      " · Message purge queued"
    end

    def deactivating?(kind) = kind == MemberGuard::DEACTIVATION && !may_deactivate?

    def channel_id = params[:channel_id].to_s.strip

    def lift_reason = params[:lift_reason].to_s.strip.presence

    def label(key) = FdHelper::ACTION_LABELS.fetch(key, key).downcase

    def display_name(user_id) = Names.for([user_id])[user_id]

    def end_time = @end_time ||= EndTime.read(params[:expires_on], params[:expires_time])

    def expiry = end_time.first

    def expiry_error = end_time.last

    def guard_error
      return "Select a guard kind" unless MemberGuard::KINDS.include?(kind)
      return "#{subject_id} is not a member id" unless subject_id.match?(MEMBER_ID)
      if kind == MemberGuard::CHANNEL_BAN && !channel_id.match?(SlackLink::CHANNEL)
        return "Channel ban needs a channel"
      end
      return expiry_error if expiry_error
      start_error = start_time.last || StartTime.error(starts_at, expiry)
      return start_error if start_error
      if params[:reason].to_s.strip.blank?
        return field_error!(:reason, "Enter a reason", params[:reason])
      end

      nil
    end

    def open_guard
      guard = MemberGuard.open!(
        kind: kind, subject_id: subject_id,
        channel_id: kind == MemberGuard::CHANNEL_BAN ? channel_id : nil,
        by: current_account.user_id, reason: params[:reason].to_s.strip,
        expires_at: expiry, starts_at: starts_at
      )
      audit(guard, guard.scheduled? ? "scheduled" : "opened") if guard
      guard
    end
  end
end
