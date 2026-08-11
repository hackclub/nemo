module Fd
  class Note < ApplicationRecord
    self.table_name = "fd.notes"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id,
      inverse_of: :notes, optional: true

    scope :visible, -> { where(deleted_at: nil) }
    scope :recent_first, -> { order(created_at: :desc) }
    scope :for_case, ->(case_id) { where(case_id: case_id) }
    scope :standing, -> { where(case_id: nil).where.not(subject_user_id: nil) }

    def self.for_subject(user_id)
      return none if user_id.blank?

      standing.where(subject_user_id: user_id)
    end

    def deleted?
      deleted_at.present?
    end

    def standing?
      case_id.nil?
    end

    def edited?
      updated_at.present? && created_at.present? && updated_at > created_at
    end
  end
end
