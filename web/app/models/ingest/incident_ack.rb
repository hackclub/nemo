module Ingest
  class IncidentAck < ApplicationRecord
    self.table_name = "ingest.incident_ack"

    KINDS = %w[source_failing credential quality].freeze

    validates :source_key, presence: true
    validates :kind, presence: true, inclusion: { in: KINDS }

    def muted?
      muted_until.present? && muted_until > Time.current
    end
  end
end
