module Fd
  class IntakeConversation < ApplicationRecord
    self.table_name = "fd.intake_conversations"

    belongs_to :report, class_name: "Fd::CaseReport", foreign_key: :report_id, optional: true
    has_many :queued, class_name: "Fd::IntakeOutbox", foreign_key: :conversation_id,
      inverse_of: :conversation, dependent: nil

    scope :open_ones, -> { where(closed_at: nil) }

    def self.for_case(case_id)
      where(report_id: CaseReport.where(case_id: case_id).select(:id)).order(:opened_at)
    end

    def closed?
      closed_at.present?
    end
  end
end
