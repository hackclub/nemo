module FireEngine
  class MembersController < BaseController
    MOCK_CONDUCT_REPORTS_FILED = 2

    def show
      @member = Moderation::MemberProfile.find(params[:id])
      @activity = Analytics::MemberActivity.where(user_id: @member.user_id).order(window_end: :desc).first
      @case_actions = LylaClient.new.case_actions_for_member(@member.user_id)["actions"].map { |a| LylaCaseActionPresenter.build(a) }
      @notes = (LylaClient.new.notes_for_member(@member.user_id) || []).map { |n| note_summary(n) }
      @conduct_reports_filed = MOCK_CONDUCT_REPORTS_FILED
      AccessLog.record!(actor: current_staff, subject_user_id: @member.user_id)
    rescue ActiveRecord::RecordNotFound
      redirect_to fire_engine_root_path, alert: "no member found for that id"
    end

    private

    def note_summary(n)
      {
        author: n["createdBy"],
        body: n["body"],
        created_at: Time.at(n["createdAt"] / 1000.0)
      }
    end
  end
end
