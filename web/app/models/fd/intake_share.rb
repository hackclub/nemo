module Fd
  class IntakeShare < ApplicationRecord
    self.table_name = "fd.intake_shares"

    FORWARD = "forward".freeze

    WHAT_IT_IS = {
      "forward" => "forwarded",
      "unfurl" => "linked",
      "link" => "linked"
    }.freeze

    def forwarded?
      kind == FORWARD
    end

    def said?
      is_reachable && source_body.present?
    end

    def word
      WHAT_IT_IS.fetch(kind, "linked")
    end

    def why_not
      "a link we could not open" unless said?
    end

    def self.for_messages(message_ids)
      ids = Array(message_ids).compact.uniq
      return {} if ids.empty?

      where(message_id: ids).order(:message_id, :id).group_by(&:message_id)
    end
  end
end
