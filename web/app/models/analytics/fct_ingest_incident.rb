module Analytics
  class FctIngestIncident < ApplicationRecord
    self.table_name = "analytics.fct_ingest_incident"
    self.primary_key = nil

    scope :open, -> { where(muted: false) }
    scope :worst_first, -> { order(consecutive: :desc, last_seen: :desc) }

    def readonly?
      true
    end
  end
end
