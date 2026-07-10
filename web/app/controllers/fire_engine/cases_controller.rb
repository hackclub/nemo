module FireEngine
  class CasesController < BaseController
    MOCK_CASES = [
      { case_number: 1042, status: "open", target_user_id: "U0A5PLKMB25", assignee: "U01MOCKFD1", opened_at: 2.days.ago, age_days: 2, channel: "shroud-logs", thread_ts: "1720000001.000100", linked_report_id: 4821 },
      { case_number: 1041, status: "open", target_user_id: "U0B9MOCKXY", assignee: nil, opened_at: 5.days.ago, age_days: 5, channel: "hq-firehouse", thread_ts: "1719700002.000200", linked_report_id: nil },
      { case_number: 1039, status: "open", target_user_id: "U0C4MOCKLM", assignee: "U01MOCKFD2", opened_at: 6.days.ago, age_days: 6, channel: "shroud-logs", thread_ts: "1719600003.000300", linked_report_id: 4790 },
      { case_number: 1038, status: "resolved", target_user_id: "U0C4MOCKLM", assignee: "U01MOCKFD1", opened_at: 9.days.ago, age_days: 9, channel: "shroud-logs", thread_ts: "1719300004.000400", linked_report_id: 4756 },
      { case_number: 1035, status: "resolved", target_user_id: "U0D2MOCKQR", assignee: "U01MOCKFD2", opened_at: 14.days.ago, age_days: 14, channel: "hq-firehouse", thread_ts: "1718800005.000500", linked_report_id: nil }
    ].freeze

    MOCK_THREAD_MESSAGES = [
      { user_id: "U0A5PLKMB25", text: "yeah i don't think that was okay to post in #general", posted_at: 2.days.ago - 4.minutes, reactions: [] },
      { user_id: "U01MOCKFD1", text: "on it, opening a case", posted_at: 2.days.ago - 3.minutes, reactions: [{ name: "hourglass", count: 1, reacted_by_current_case: true }] },
      { user_id: "U0B4RANDOM1", text: "same person did this last week too", posted_at: 2.days.ago - 1.minute, reactions: [{ name: "eyes", count: 2 }] },
      { user_id: "U01MOCKFD1", text: "confirmed, second occurrence — escalating to a warning", posted_at: 2.days.ago, reactions: [{ name: "hourglass", count: 1 }] }
    ].freeze

    MOCK_ACTION_TYPE_OPTIONS = %w[warning temp_ban indef_ban perma_ban dm shush channel_ban locked_thread].freeze
    MOCK_CATEGORY_OPTIONS = ["NSFW content", "Harassment", "Spam", "Impersonation", "Other"].freeze

    def index
      @cases = MOCK_CASES
      @open_count = @cases.count { |c| c[:status] == "open" }
      @unassigned_count = @cases.count { |c| c[:status] == "open" && c[:assignee].nil? }
      @aging_count = @cases.count { |c| c[:status] == "open" && c[:age_days] >= 5 }
    end

    def show
      @case = MOCK_CASES.find { |c| c[:case_number] == params[:id].to_i }
      return redirect_to(fire_engine_cases_path, alert: "no case found for that number") unless @case

      @all_cases = MOCK_CASES
      @thread_messages = MOCK_THREAD_MESSAGES
      @case_actions = FireEngine::MembersController::MOCK_CASE_ACTIONS
      @action_type_options = MOCK_ACTION_TYPE_OPTIONS
      @category_options = MOCK_CATEGORY_OPTIONS
    end
  end
end
