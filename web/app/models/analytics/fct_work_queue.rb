module Analytics
  class FctWorkQueue < ApplicationRecord
    self.table_name = "analytics.fct_work_queue"
    self.primary_key = "work_kind"

    scope :busiest_first, -> { order(pending: :desc, work_kind: :asc) }

    def open
      pending + claimed
    end

    def readonly?
      true
    end
  end
end
