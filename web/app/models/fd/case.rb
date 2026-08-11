module Fd
  class Case < ApplicationRecord
    self.table_name = "fd.cases"

    RESOLUTIONS = %w[action_taken no_action duplicate not_conduct].freeze

    has_many :threads, class_name: "Fd::CaseThread", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :participants, class_name: "Fd::CaseParticipant", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil

    scope :unresolved, -> { where(resolved_at: nil) }
    scope :oldest_first, -> { order(:opened_at) }

    def resolved?
      resolved_at.present?
    end

    def claimed?
      claimed_by.present?
    end

    def primary_thread
      threads.detect(&:is_primary)
    end

    def sibling_cases
      pairs = threads.map(&:coordinates)
      return Case.none if pairs.empty?

      tuples = Array.new(pairs.size, "(?, ?)").join(", ")
      ids = CaseThread
        .where("(channel_id, thread_ts) IN (#{tuples})", *pairs.flatten)
        .where.not(case_id: id)
        .distinct
        .pluck(:case_id)
      ids.any? ? Case.where(id: ids) : Case.none
    end
  end
end
