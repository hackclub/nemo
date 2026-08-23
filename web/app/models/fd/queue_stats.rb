module Fd
  class QueueStats
    SQL = <<~SQL.freeze
      SELECT
        count(*) AS total,
        min(opened_at) AS first_opened,
        count(*) FILTER (WHERE resolved_at IS NULL) AS open_count,
        count(*) FILTER (
          WHERE resolved_at IS NULL
            AND NOT EXISTS (SELECT 1 FROM fd.actions a WHERE a.case_id = c.id)
        ) AS open_no_action,
        count(*) FILTER (
          WHERE resolved_at IS NULL
            AND NOT EXISTS (SELECT 1 FROM fd.case_assignees x WHERE x.case_id = c.id)
        ) AS unassigned,
        min(opened_at) FILTER (
          WHERE resolved_at IS NULL
            AND NOT EXISTS (SELECT 1 FROM fd.case_assignees x WHERE x.case_id = c.id)
        ) AS oldest_unassigned,
        count(*) FILTER (WHERE opened_at >= :month) AS opened_month,
        count(*) FILTER (
          WHERE opened_at >= :month AND resolved_at IS NOT NULL AND duplicate_of IS NULL
        ) AS opened_month_resolved,
        percentile_cont(0.5) WITHIN GROUP (
          ORDER BY extract(epoch FROM resolved_at - opened_at)
        ) FILTER (WHERE resolved_at >= :quarter AND duplicate_of IS NULL) AS median_now,
        percentile_cont(0.5) WITHIN GROUP (
          ORDER BY extract(epoch FROM resolved_at - opened_at)
        ) FILTER (
          WHERE resolved_at >= :last_quarter AND resolved_at < :quarter
            AND duplicate_of IS NULL
        ) AS median_before
      FROM fd.cases c
    SQL

    def self.load(now: Time.current)
      quarter = now.beginning_of_quarter
      binds = {
        month: now.beginning_of_month,
        quarter: quarter,
        last_quarter: quarter - 3.months
      }
      new(Case.connection.select_one(Case.sanitize_sql([SQL, binds])))
    end

    def initialize(row)
      @row = row
    end

    def total = @row["total"].to_i
    def open_count = @row["open_count"].to_i
    def open_no_action = @row["open_no_action"].to_i
    def unassigned = @row["unassigned"].to_i
    def opened_month = @row["opened_month"].to_i
    def opened_month_resolved = @row["opened_month_resolved"].to_i

    def first_opened
      @row["first_opened"]&.to_time
    end

    def oldest_unassigned
      @row["oldest_unassigned"]&.to_time
    end

    def median_now = @row["median_now"]&.to_f
    def median_before = @row["median_before"]&.to_f
  end
end
