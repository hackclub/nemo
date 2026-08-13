module Fd
  class CaseReport < ApplicationRecord
    self.table_name = "fd.case_reports"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :reports

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

    def told_of_outcome?
      closed_at.present?
    end
  end
end
