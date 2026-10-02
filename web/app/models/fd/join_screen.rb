module Fd
  class JoinScreen < ApplicationRecord
    self.table_name = "fd.join_screen"

    ALLOWED = "allowed".freeze
    FLAGGED = "flagged".freeze
    HELD = "held".freeze
    DEACTIVATED = "deactivated".freeze
    FAILED = "failed".freeze
    NO_EMAIL = "no_email".freeze

    CAUGHT = [FLAGGED, HELD, DEACTIVATED, FAILED].freeze

    belongs_to :blocked_domain, class_name: "Fd::BlockedDomain", foreign_key: :domain_id,
      optional: true, inverse_of: false

    scope :recent_first, -> { order(at: :desc, id: :desc) }
    scope :caught, -> { where(outcome: CAUGHT) }

    def readonly?
      persisted?
    end

    def caught? = CAUGHT.include?(outcome)

    def people_named = [user_id].compact
  end
end
