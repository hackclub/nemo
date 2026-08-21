module Fd
  class IntakeOutbox < ApplicationRecord
    self.table_name = "fd.intake_outbox"

    KINDS = %w[reply outcome].freeze
    MODES = %w[body signed].freeze
    MAX_LENGTH = 4_000

    belongs_to :conversation, class_name: "Fd::IntakeConversation",
      foreign_key: :conversation_id, inverse_of: :queued

    scope :waiting, -> { where(sent_at: nil, failed_at: nil) }
    scope :oldest_first, -> { order(:requested_at) }

    def sent?
      sent_at.present?
    end

    def failed?
      failed_at.present?
    end

    def state
      return "sent" if sent?
      return "undelivered" if failed?

      "queued"
    end
  end
end
