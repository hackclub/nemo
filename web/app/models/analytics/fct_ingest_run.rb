module Analytics
  class FctIngestRun < ApplicationRecord
    self.table_name = "analytics.fct_ingest_run"
    self.primary_key = "id"

    PARENT_SOURCE = "nightly_sync".freeze

    scope :parents, -> { where(parent_run_id: nil, source: PARENT_SOURCE) }
    scope :recent_first, -> { order(started_at: :desc) }

    def readonly?
      true
    end

    def running?
      status == "running"
    end

    def abandoned?
      status == "abandoned"
    end

    def seconds
      return nil if abandoned?

      ((finished_at || Time.current) - started_at).to_i
    end

    def age_from
      return started_at if abandoned?

      finished_at || started_at
    end
  end
end
