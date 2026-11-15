module Fd
  class ReactivationsController < BaseController
    include ReactivatesMembers

    permit "member.deactivate"

    def create
      subject_id = params[:member_id].to_s
      reason = params[:reason].to_s.strip.presence
      if reason.nil?
        field_error!(:reactivate_reason, "Enter a reason")
        return redirect_to(fd_member_path(subject_id, do: "reactivate"))
      end

      guard = standing_deactivation(subject_id)
      return redirect_to(fd_member_path(subject_id), alert: "Set in Firehose") if guard&.firehose?

      lifted = nil
      ended = []
      writing do
        guard ||= record_deactivation(subject_id)
        lifted = lift_deactivation(guard, reason) if guard
        ended = end_bans(subject_id, reason)
      end

      name = Names.for([subject_id])[subject_id]
      return redirect_to(fd_member_path(subject_id), alert: "#{name} is not deactivated") if lifted.nil? && ended.empty?

      redirect_to fd_member_path(subject_id), notice: reactivation_notice(lifted, ended, name)
    end
  end
end
