module Fd
  class MemberGuardsController < BaseController
    permit "member.guard"

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def create
      return refuse!("member.deactivate") if deactivating?(kind)

      problem = guard_objection
      if problem
        return redirect_to(fd_member_path(subject_id, do: "guard"),
          alert: (problem unless flash[:wrong]))
      end

      guard = nil
      writing { guard = open_standing }

      if guard.nil?
        return redirect_to fd_member_path(subject_id),
          alert: "#{named(subject_id)} is already under a #{label(kind)}"
      end

      redirect_to fd_member_path(subject_id),
        notice: "#{label(kind)} held on #{named(subject_id)}, on no case"
    end

    def update
      guard = MemberGuard.still_on.find(params[:id])
      return refuse!("member.deactivate", guard) if deactivating?(guard.kind)

      if expiry.nil?
        return redirect_to fd_member_path(guard.subject_id),
          alert: "say the date it should run until"
      end

      was = guard.expires_at
      writing do
        guard.run_until!(expiry)
        audit(guard, "extended", before: { "expires_at" => was },
          after: { "expires_at" => expiry })
      end

      redirect_to fd_member_path(guard.subject_id),
        notice: "#{label(guard.kind)} now runs until #{expiry.strftime("%-d %b")}"
    end

    def destroy
      guard = MemberGuard.still_on.find(params[:id])
      return refuse!("member.deactivate", guard) if deactivating?(guard.kind)

      was = guard.state
      writing do
        guard.lift!(by: current_account.user_id, reason: lift_reason)
        audit(guard, "lifted", before: { "state" => was },
          after: { "state" => guard.state, "lift_reason" => lift_reason })
      end

      redirect_to fd_member_path(guard.subject_id),
        notice: "#{label(guard.kind)} lifted on #{named(guard.subject_id)}"
    end

    private

    def subject_id = params[:member_id].to_s.upcase

    def kind = params[:kind].to_s

    def may_deactivate? = current_account&.may?("member.deactivate")

    def deactivating?(said) = said == MemberGuard::DEACTIVATION && !may_deactivate?

    def channel_id = params[:channel_id].to_s.strip

    def lift_reason = params[:lift_reason].to_s.strip.presence

    def label(key) = FdHelper::ACTION_LABELS.fetch(key, key).downcase

    def named(user_id) = Names.for([user_id])[user_id]

    def said_when = params[:expires_on].to_s.strip

    def expiry
      return nil if said_when.blank?

      Date.strptime(said_when, "%Y-%m-%d").end_of_day
    rescue Date::Error
      nil
    end

    def guard_objection
      return "pick what to hold" unless MemberGuard::KINDS.include?(kind)
      return "#{subject_id} is not a member id" unless subject_id.match?(MEMBER_ID)
      if kind == MemberGuard::CHANNEL_BAN && !channel_id.match?(SlackLink::CHANNEL)
        return "a channel ban needs a channel"
      end
      return "#{said_when} is not a date" if expiry.nil? && said_when.present?
      if expiry.nil? && !MemberGuard::DATELESS.include?(kind)
        return "say the date it runs until"
      end
      if params[:reason].to_s.strip.blank?
        return wrong!(:reason, "say why this is being held", params[:reason])
      end

      nil
    end

    def open_standing
      guard = MemberGuard.open!(
        kind: kind, subject_id: subject_id,
        channel_id: kind == MemberGuard::CHANNEL_BAN ? channel_id : nil,
        by: current_account.user_id, reason: params[:reason].to_s.strip,
        expires_at: expiry
      )
      audit(guard, "opened") if guard
      guard
    end
  end
end
