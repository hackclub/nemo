module FireEngine
  class HomeController < BaseController
    MOCK_CASES_SUMMARY = {
      open_count: 7,
      unassigned_count: 2,
      aging_5d_plus: 1,
      trend: "+2 this week"
    }.freeze

    MOCK_REPORTS_SUMMARY = {
      open_count: 4,
      median_reply_minutes: 18,
      median_resolve_hours: 4.2,
      trend: "-1 this week"
    }.freeze

    def index
      if params[:q].present?
        q = params[:q].strip
        @results = Moderation::MemberProfile
          .where("user_id = :exact OR username ILIKE :like OR email ILIKE :like OR name ILIKE :like",
                 exact: q, like: "%#{q}%")
          .order(:user_id)
          .limit(25)
      end

      @cases_summary = MOCK_CASES_SUMMARY
      @reports_summary = MOCK_REPORTS_SUMMARY
      @recent = AccessLog.where(actor_id: current_staff.user_id).order(looked_at: :desc).limit(10)
      @lookups_today = AccessLog.where(actor_id: current_staff.user_id)
        .where("looked_at >= ?", Time.current.beginning_of_day)
        .count
    end
  end
end
