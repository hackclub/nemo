module Fd
  class CaseParticipant < ApplicationRecord
    self.table_name = "fd.case_participants"
    self.primary_key = [:case_id, :user_id, :role]

    ROLES = %w[target reporter witness participant].freeze

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :participants

    scope :by_role, -> { order(:role, :user_id) }
  end
end
