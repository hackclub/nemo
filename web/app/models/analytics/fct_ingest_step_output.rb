module Analytics
  class FctIngestStepOutput < ApplicationRecord
    self.table_name = "analytics.fct_ingest_step_output"
    self.primary_key = "parent_run_id"

    def readonly?
      true
    end
  end
end
