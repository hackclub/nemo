module Fd
  class CaseReport < ApplicationRecord
    self.table_name = "fd.case_reports"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :reports

    SHROUD_AUTHORS = %w[U07K4TS9HQE B07KBDVFXJP].freeze

    scope :oldest_first, -> { order(:received_at) }

    def self.threads_besides(reports, selected)
      return [] if selected.nil?

      reports.filter_map(&:forwarded_ts).uniq - [selected.forwarded_ts]
    end

    def self.shroud_reports_by_thread(chat)
      lines = chat.select { |line| shroud_relay?(line) }
      return {} if lines.empty?

      where(source_app: "shroud", card_channel_id: lines.map(&:channel_id).uniq,
        forwarded_ts: lines.map(&:thread_ts).uniq)
        .index_by { |report| [report.card_channel_id, report.forwarded_ts] }
    end

    def self.shroud_relay?(line)
      SHROUD_AUTHORS.include?(line.author_user_id) && line.ts.present? && line.ts != line.thread_ts
    end

    def anonymous?
      is_anonymous
    end

    def reporter_label(names = nil)
      return "Anonymous" if anonymous?

      names ? names[reporter_user_id] : "@#{reporter_user_id}"
    end

    def replied?
      first_replied_at.present?
    end

    def reply_latency
      return nil unless replied?

      first_replied_at - received_at
    end

    def unanswered?
      first_replied_at.nil?
    end

    def waiting_for(now = Time.current)
      return nil if replied?

      now - received_at
    end

    def outcome_notified?
      closed_at.present?
    end

    def closed_line(names)
      return nil unless outcome_notified?

      "outcome sent #{closed_at.strftime('%-d %b')} by #{names[closed_by]}"
    end
  end
end
