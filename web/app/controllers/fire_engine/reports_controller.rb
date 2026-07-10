module FireEngine
  class ReportsController < BaseController
    MOCK_SUMMARY = {
      open_count: 4,
      resolved_last_30d: 42,
      median_reply_minutes: 18,
      median_resolve_hours: 4.2
    }.freeze

    MOCK_RECENT_REPORTS = [
      { id: 4821, filed_at: 6.hours.ago, content: "posted nsfw content in #general, repeat offender", auto_forwarded: true, linked_case_number: 1042 },
      { id: 4805, filed_at: 1.day.ago, content: "someone ban evading, same writing style as a banned user", auto_forwarded: false, linked_case_number: nil },
      { id: 4790, filed_at: 2.days.ago, content: "harassment in dms, screenshots attached", auto_forwarded: true, linked_case_number: 1039 },
      { id: 4756, filed_at: 3.days.ago, content: "spam links across several channels", auto_forwarded: false, linked_case_number: 1038 }
    ].freeze

    def index
      @summary = MOCK_SUMMARY
      @recent = MOCK_RECENT_REPORTS.map { |r| r.merge(status: resolved_status(r)) }
    end

    def new
    end

    def create
      redirect_to fire_engine_reports_path,
        notice: "report filed (mock — not yet wired to shroud)"
    end

    def edit
      @report = MOCK_RECENT_REPORTS.find { |r| r[:id] == params[:id].to_i }
      return redirect_to(fire_engine_reports_path, alert: "no report found for that id") unless @report
    end

    def update
      redirect_to fire_engine_reports_path,
        notice: "report ##{params[:id]} updated (mock — not yet wired to shroud)"
    end

    private

    # Mirrors the planned real logic: resolved status comes from the linked
    # Lyla case's status, not Shroud's own resolve_time, once a case exists.
    def resolved_status(report)
      return CasesController::MOCK_CASES.find { |c| c[:case_number] == report[:linked_case_number] }[:status] if report[:linked_case_number]

      "no case linked"
    end
  end
end
