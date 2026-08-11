module Fd
  class CaseThread < ApplicationRecord
    self.table_name = "fd.case_threads"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :threads

    scope :primary_first, -> { order(is_primary: :desc, added_at: :asc) }

    def coordinates
      [channel_id, thread_ts]
    end
  end
end
