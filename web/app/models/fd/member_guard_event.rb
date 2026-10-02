module Fd
  class MemberGuardEvent < ApplicationRecord
    self.table_name = "fd.member_guard_events"

    HELD = "held".freeze
    RELEASED = "released".freeze
    FAILED = "failed".freeze
    DELETED = "deleted".freeze
    KICKED = "kicked".freeze
    LET_PAST = "let_past".freeze
    TOLD = "told".freeze

    belongs_to :guard, class_name: "Fd::MemberGuard", foreign_key: :guard_id,
      inverse_of: :events

    scope :newest_first, -> { order(at: :desc) }
    scope :turned_away, -> { where(verb: [DELETED, KICKED]) }

    def readonly?
      persisted?
    end
  end
end
