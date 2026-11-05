module Fd
  class MemberStandingsController < BaseController
    permit "case.read"

    def show
      user_id = params[:member_id].to_s.upcase
      guards = MemberGuard.by_severity(MemberGuard.standing_on(user_id))
      scheduled = MemberGuard.scheduled.for_subject(user_id).oldest_first.to_a

      render partial: "fd/members/standing", layout: false, locals: {
        user_id: user_id, guards: guards, scheduled: scheduled,
        names: Names.for(referenced_user_ids(guards + scheduled) + [user_id]),
        may_guard: current_account.may?("member.guard"),
        may_deactivate: current_account.may?("member.deactivate")
      }
    end

    private

    def referenced_user_ids(guards)
      guards.flat_map(&:referenced_user_ids) + guards.map(&:subject_id)
    end
  end
end
