module Fd
  class MemberStandingsController < BaseController
    permit "case.read"

    def show
      user_id = params[:member_id].to_s.upcase
      guards = MemberGuard.worst_first(MemberGuard.standing_on(user_id))

      render partial: "fd/members/standing", layout: false, locals: {
        user_id: user_id, guards: guards, names: Names.for(named(guards) + [user_id]),
        may_guard: current_account.may?("member.guard"),
        may_deactivate: current_account.may?("member.deactivate")
      }
    end

    private

    def named(guards)
      guards.flat_map(&:people_named) + guards.map(&:subject_id)
    end
  end
end
