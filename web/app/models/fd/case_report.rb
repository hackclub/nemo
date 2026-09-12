module Fd
  class CaseReport < ApplicationRecord
    self.table_name = "fd.case_reports"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :reports
    has_many :conversations, class_name: "Fd::IntakeConversation", foreign_key: :report_id,
      inverse_of: :report, dependent: nil

    scope :oldest_first, -> { order(:received_at) }

    def anonymous?
      is_anonymous
    end

    def reporter_label(names = nil)
      return "anonymous" if anonymous?

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

    # closed_at only means the case finished handling this report and meant to tell
    # them; it is set the moment that is requested, before delivery is attempted. The
    # outbox row is the source of truth for whether the reporter actually heard back.
    def outcome_message
      IntakeOutbox.where(kind: "outcome", conversation_id: conversations.select(:id))
        .order(requested_at: :desc).first
    end

    def outcome_state
      return :sent if outcome_message&.sent?
      return :failed if outcome_message&.failed?
      return :queued if outcome_message
      return :unreachable if closed_at.present?

      nil
    end

    def told_of_outcome?
      outcome_state == :sent
    end

    def closed_line(names)
      return nil unless told_of_outcome?

      "told the outcome #{outcome_message.sent_at.strftime('%-d %b')} by #{names[closed_by]}"
    end
  end
end
