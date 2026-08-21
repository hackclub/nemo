module Fd
  class CaseChat < ApplicationRecord
    self.table_name = "fd.case_chat"

    MAX_LENGTH = 4_000
    SHOWN = 50

    scope :oldest_first, -> { order(:said_at, :id) }
    scope :newest_first, -> { order(said_at: :desc, id: :desc) }

    def self.tail(case_id, limit: SHOWN)
      where(case_id: case_id).newest_first.limit(limit).to_a.reverse
    end

    def self.earlier_than(case_id, shown)
      [where(case_id: case_id).count - shown, 0].max
    end

    def deleted?
      deleted_at.present?
    end

    def edited?
      edited_at.present?
    end

    def from_slack?
      ts.present?
    end
  end
end
