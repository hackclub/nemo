module Fd
  class IntakeFile < ApplicationRecord
    self.table_name = "fd.intake_files"

    KEPT = "stored".freeze
    IMAGE = %r{\Aimage/}
    SHOWN_INLINE = %w[image/png image/jpeg image/gif image/webp].freeze

    WHY_NOT = {
      "pending" => "not kept yet",
      "purged" => "purged",
      "gone" => "gone from Slack",
      "too_large" => "too large to keep",
      "refused" => "could not be kept",
      "failed" => "could not be kept",
      "skipped" => "not kept"
    }.freeze

    def kept?
      fetch_state == KEPT && stored_key.present?
    end

    def image?
      kept? && mimetype.to_s.match?(IMAGE)
    end

    def inline?
      SHOWN_INLINE.include?(mimetype.to_s.downcase)
    end

    def shown_name
      name.presence || title.presence || "attachment"
    end

    def said
      kept? ? nil : WHY_NOT.fetch(fetch_state, "could not be kept")
    end

    def self.for_messages(message_ids)
      ids = Array(message_ids).compact.uniq
      return {} if ids.empty?

      select("fd.intake_files.*, mf.message_id AS held_by, mf.seq AS held_seq")
        .joins("JOIN fd.intake_message_files mf ON mf.file_id = fd.intake_files.id")
        .where("mf.message_id IN (?)", ids)
        .order(Arel.sql("mf.message_id, mf.seq"))
        .group_by { |row| row.held_by.to_i }
    end
  end
end
