module Fd
  class CaseThread < ApplicationRecord
    self.table_name = "fd.case_threads"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :threads

    KINDS = %w[evidence internal].freeze

    scope :primary_first, -> { order(is_primary: :desc, added_at: :asc) }
    scope :evidence, -> { where(kind: "evidence") }
    scope :internal, -> { where(kind: "internal") }

    def coordinates
      [channel_id, thread_ts]
    end

    def evidence?
      kind == "evidence"
    end

    def internal?
      kind == "internal"
    end
  end
end
