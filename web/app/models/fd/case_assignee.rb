module Fd
  class CaseAssignee < ApplicationRecord
    self.table_name = "fd.case_assignees"
    self.primary_key = [:case_id, :user_id]

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :assignees

    scope :oldest_first, -> { order(:assigned_at, :user_id) }
  end
end
