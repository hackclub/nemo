module FireEngine
  class ReportsController < BaseController
    def index
      reports = shroud.list(limit: 100) || []
      thread_index = build_thread_index(lyla.cases || [])

      @recent = reports.map { |r| report_summary(r, thread_index) }.sort_by { |r| r[:filed_at] || Time.zone.at(0) }.reverse
      @summary = build_summary(@recent)
    end

    def new
    end

    def create
      shroud.create(content: params[:content])
      redirect_to fire_engine_reports_path, notice: "report filed"
    rescue ShroudReportsClient::Error => e
      redirect_to new_fire_engine_report_path, alert: "could not file report: #{e.message}"
    end

    def edit
      raw = shroud.find(params[:id])
      return redirect_to(fire_engine_reports_path, alert: "no report found for that id") unless raw

      @report = report_summary(raw, build_thread_index(lyla.cases || []))
    end

    def update
      if params[:mark_resolved].present?
        raw = shroud.find(params[:id])
        forwarded_ts = raw&.dig("fields", "forwarded_ts")
        shroud.update(params[:id], resolve_time: (Time.current.to_f - forwarded_ts.to_f).round) if forwarded_ts
      elsif params[:mark_merged].present?
        shroud.update(params[:id], merged: true)
      end

      redirect_to fire_engine_reports_path, notice: "report ##{params[:id]} updated"
    rescue ShroudReportsClient::Error => e
      redirect_to edit_fire_engine_report_path(params[:id]), alert: "could not update report: #{e.message}"
    end

    private

    def shroud
      @shroud ||= ShroudReportsClient.new
    end

    def lyla
      @lyla ||= LylaClient.new
    end

    def build_thread_index(cases)
      cases.each_with_object({}) do |c, index|
        (c["threads"] || []).each { |t| index[t["threadTs"]] = c }
      end
    end

    def report_summary(raw, thread_index)
      f = raw["fields"] || {}
      linked_case = thread_index[f["forwarded_ts"]]

      {
        id: raw["id"],
        filed_at: f["created_at"].presence && Time.zone.parse(f["created_at"]),
        content: f["content"],
        auto_forwarded: !!f["is_auto_forward"],
        reply_time: f["reply_time"],
        resolve_time: f["resolve_time"],
        status: derive_status(f, linked_case),
        linked_case_number: linked_case&.dig("caseNumber")
      }
    end

    def derive_status(f, linked_case)
      return linked_case["status"] if linked_case
      return "not yet forwarded" if f["forwarded_ts"].blank?
      return "resolved" if f["resolve_time"].present?

      "no case linked"
    end

    def build_summary(recent)
      reply_median = median(recent.filter_map { |r| r[:reply_time] })
      resolve_median = median(recent.filter_map { |r| r[:resolve_time] })

      {
        open_count: recent.count { |r| r[:status] == "open" },
        resolved_last_30d: recent.count { |r| r[:status] == "resolved" && r[:filed_at] && r[:filed_at] > 30.days.ago },
        median_reply_minutes: reply_median && (reply_median / 60.0).round(1),
        median_resolve_hours: resolve_median && (resolve_median / 3600.0).round(1)
      }
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.length / 2
      sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
