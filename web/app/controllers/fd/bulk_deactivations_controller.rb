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
      @wanted ||= Array(params[:user_ids]).map { |said| said.to_s.strip.upcase }
        .select { |said| said.match?(MEMBER_ID) }.uniq
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
      said = "#{helpers.pluralize(opened, 'account')} sent to nemo to deactivate"
      return said if opened == wanted.size

      "#{said}, #{wanted.size - opened} already had one standing"
    end

    def refuse(said)
      redirect_to here, alert: (said unless flash[:wrong])
    end
  end
end
