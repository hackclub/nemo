module Fd
  class BulkDeactivationsController < BaseController
    permit "member.deactivate"

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/
    MOST = 100
    NO_REASON = "deactivated in bulk from the joiners page".freeze

    def create
      problem = objection
      return refuse(problem) if problem

      opened = 0
      writing do
        opened = wanted.count { |user_id| open_one(user_id) }
      end

      redirect_to here, notice: notice_for(opened)
    end

    private

    def wanted
      @wanted ||= Array(params[:user_ids]).map { |one| one.to_s.strip.upcase }
        .select { |one| one.match?(MEMBER_ID) }.uniq
    end

    def reason = params[:reason].to_s.strip.presence || NO_REASON

    def here = fd_joiners_path(params.permit(*JoinerQuery::KEYS).to_h.compact_blank)

    def objection
      return "pick who this is about" if wanted.empty?
      return "that is more than #{MOST} accounts at once" if wanted.size > MOST

      nil
    end

    def open_one(user_id)
      guard = MemberGuard.open!(kind: MemberGuard::DEACTIVATION, subject_id: user_id,
        by: current_account.user_id, reason: reason)
      return false if guard.nil?

      audit(guard, "opened")
      true
    end

    def notice_for(opened)
      one = "#{helpers.pluralize(opened, 'account')} sent to nemo to deactivate"
      return one if opened == wanted.size

      "#{one}, #{wanted.size - opened} already had one standing"
    end

    def refuse(one)
      redirect_to here, alert: (one unless flash[:field_error])
    end
  end
end
