module Fd
  class CaseMerge < ApplicationRecord
    self.table_name = "fd.case_merges"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: false
    belongs_to :into_case, class_name: "Fd::Case", inverse_of: false

    scope :live, -> { where(unmerged_at: nil) }

    def prior_resolved?
      prior_resolution.present? && prior_resolved_at.present?
    end
  end
end
