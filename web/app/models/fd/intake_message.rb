module Fd
  class IntakeMessage < ApplicationRecord
    self.table_name = "fd.intake_messages"

    SHOWN = 50

    belongs_to :conversation, class_name: "Fd::IntakeConversation",
      foreign_key: :conversation_id, inverse_of: nil

    scope :oldest_first, -> { order(:posted_at, :id) }
    scope :newest_first, -> { order(posted_at: :desc, id: :desc) }
    scope :from_them, -> { where(direction: "inbound") }
    scope :from_us, -> { where(direction: "outbound") }

    def self.tail(conversation_ids, limit: SHOWN)
      return [] if conversation_ids.blank?

      where(conversation_id: conversation_ids).newest_first.limit(limit).to_a.reverse
    end

    def theirs?
      direction == "inbound"
    end

    def deleted?
      deleted_at.present?
    end

    def edited?
      edited_at.present?
    end
  end
end
