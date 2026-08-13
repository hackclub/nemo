module Fd
  class DecisionThread < ApplicationRecord
    self.table_name = "fd.decision_threads"

    belongs_to :decision, class_name: "Fd::Decision", foreign_key: :decision_id,
      inverse_of: :threads

    scope :oldest_first, -> { order(:added_at) }

    def why=(value)
      super(value.to_s.strip.presence)
    end

    def coordinates
      [channel_id, thread_ts]
    end

    def said_why?
      why.present?
    end
  end
end
