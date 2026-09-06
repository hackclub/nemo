module Analytics
  class FctSliceCoverage < ApplicationRecord
    self.table_name = "analytics.fct_slice_coverage"
    self.primary_key = "slice_coverage_id"

    STATES = %w[claimed complete short superseded unavailable].freeze

    scope :for_source, ->(key) { where(source_key: key) }
    scope :live, -> { where.not(state: "superseded") }
    scope :missing, -> { where(state: %w[short claimed]) }
    scope :newest_first, -> { order(slice_end: :desc, slice_key: :desc) }

    def readonly?
      true
    end
  end
end
