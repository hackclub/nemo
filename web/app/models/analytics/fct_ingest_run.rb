module Analytics
  class FctIngestRun < ApplicationRecord
    self.table_name = "analytics.fct_ingest_run"

    PARENT_SOURCE = "nightly_sync".freeze

    scope :parents, -> { where(parent_run_id: nil, source: PARENT_SOURCE) }
    scope :recent_first, -> { order(started_at: :desc) }

    def readonly?
      true
    end

    def running?
      status == "running"
    end

    def seconds
      ((finished_at || Time.current) - started_at).to_i
    end
  end
end
