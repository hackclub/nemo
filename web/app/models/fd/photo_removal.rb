module Fd
  class PhotoRemoval < ApplicationRecord
    self.table_name = "fd.photo_removals"

    ASKED = "asked".freeze
    RUNNING = "running".freeze
    DONE = "done".freeze
    FAILED = "failed".freeze
    WAITING = [ASKED, RUNNING].freeze
    FINISHED = [DONE, FAILED].freeze

    belongs_to :guard, class_name: "Fd::MemberGuard", optional: true, inverse_of: false
    has_one :evidence, class_name: "Fd::PhotoRemovalEvidence", foreign_key: :removal_id,
      inverse_of: :removal, dependent: nil

    scope :for_member, ->(member_id) { where(member_id: member_id) }
    scope :waiting, -> { where(state: WAITING) }
    scope :finished, -> { where(state: FINISHED) }
    scope :newest_first, -> { order(asked_at: :desc, id: :desc) }

    def self.queue!(member_id:, asked_by:, reason: nil, guard_id: nil)
      transaction(requires_new: true) do
        create!(member_id: member_id, asked_by: asked_by, reason: reason.to_s.strip.presence,
          guard_id: guard_id)
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def audit_entity_type = "member_photo"

    def done? = state == DONE
    def failed? = state == FAILED
    def waiting? = WAITING.include?(state)

    def referenced_user_ids = [asked_by]
  end
end
