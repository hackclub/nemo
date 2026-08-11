module Fd
  class Case < ApplicationRecord
    self.table_name = "fd.cases"

    RESOLUTIONS = %w[action_taken no_action duplicate not_conduct].freeze

    scope :unresolved, -> { where(resolved_at: nil) }
    scope :oldest_first, -> { order(:opened_at) }

    def resolved?
      resolved_at.present?
    end

    def claimed?
      claimed_by.present?
    end
  end
end
