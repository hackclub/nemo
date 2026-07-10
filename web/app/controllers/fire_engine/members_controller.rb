module FireEngine
  class MembersController < BaseController
    MOCK_CASE_ACTIONS = [
      {
        case_number: 1038,
        action_type: "warning",
        performed_by: "U01MOCKFD1",
        what_they_did: "posted NSFW content in #general",
        ban_until: nil,
        performed_at: 12.days.ago,
        thread_url: "#"
      },
      {
        case_number: 1042,
        action_type: "temp_ban",
        performed_by: "U01MOCKFD1",
        what_they_did: "repeated harassment after warning",
        ban_until: 5.days.from_now,
        performed_at: 6.days.ago,
        thread_url: "#"
      }
    ].freeze

    MOCK_NOTES = [
      {
        author: "U01MOCKFD2",
        body: "keep an eye on this one, pattern of jokes that toe the line",
        created_at: 3.days.ago
      }
    ].freeze

    MOCK_CONDUCT_REPORTS_FILED = 2

    def show
      @member = Moderation::MemberProfile.find(params[:id])
      @activity = Analytics::MemberActivity.where(user_id: @member.user_id).order(window_end: :desc).first
      @case_actions = MOCK_CASE_ACTIONS
      @notes = MOCK_NOTES
      @conduct_reports_filed = MOCK_CONDUCT_REPORTS_FILED
      AccessLog.record!(actor: current_staff, subject_user_id: @member.user_id)
    rescue ActiveRecord::RecordNotFound
      redirect_to fire_engine_root_path, alert: "no member found for that id"
    end
  end
end
