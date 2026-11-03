module Fd
  class IntakeFile < ApplicationRecord
    self.table_name = "fd.intake_files"

    STORED = "stored".freeze
    IMAGE = %r{\Aimage/}
    INLINE_MIMETYPES = %w[image/png image/jpeg image/gif image/webp].freeze

    STATE_NOTES = {
      "pending" => "not stored yet",
      "purged" => "purged",
      "gone" => "deleted in Slack",
      "too_large" => "too large",
      "refused" => "not stored",
      "failed" => "not stored",
      "skipped" => "not stored"
    }.freeze

    def stored?
      fetch_state == STORED && stored_key.present?
    end

    def image?
      stored? && mimetype.to_s.match?(IMAGE)
    end

    def inline?
      INLINE_MIMETYPES.include?(mimetype.to_s.downcase)
    end

    def display_name
      name.presence || title.presence || "attachment"
    end

    def note
      stored? ? nil : STATE_NOTES.fetch(fetch_state, "not stored")
    end

    FILE_COUNTS_SQL = <<~SQL.freeze
      SELECT r.case_id, count(DISTINCT mf.file_id) AS attached_count
      FROM fd.intake_message_files mf
      JOIN fd.intake_messages m ON m.id = mf.message_id
      JOIN fd.intake_conversations v ON v.id = m.conversation_id
      JOIN fd.case_reports r ON r.id = v.report_id
      WHERE r.case_id IN (:case_ids) AND m.direction = 'inbound'
      GROUP BY r.case_id
    SQL

    def self.counts_for_cases(case_ids)
      ids = Array(case_ids).compact.uniq
      return {} if ids.empty?

      connection.select_all(sanitize_sql([FILE_COUNTS_SQL, { case_ids: ids }]))
        .to_a.to_h { |row| [row["case_id"], row["attached_count"].to_i] }
    end

    def self.for_messages(message_ids)
      ids = Array(message_ids).compact.uniq
      return {} if ids.empty?

      select("fd.intake_files.*, mf.message_id AS file_message_id, mf.seq AS file_seq")
        .joins("JOIN fd.intake_message_files mf ON mf.file_id = fd.intake_files.id")
        .where("mf.message_id IN (?)", ids)
        .order(Arel.sql("mf.message_id, mf.seq"))
        .group_by { |row| row.file_message_id.to_i }
    end

    def self.for_chat(chat_ids)
      ids = Array(chat_ids).compact.uniq
      return {} if ids.empty?

      select("fd.intake_files.*, cf.chat_id AS file_chat_id, cf.seq AS file_seq")
        .joins("JOIN fd.case_chat_files cf ON cf.file_id = fd.intake_files.id")
        .where("cf.chat_id IN (?)", ids)
        .order(Arel.sql("cf.chat_id, cf.seq"))
        .group_by { |row| row.file_chat_id.to_i }
    end
  end
end
