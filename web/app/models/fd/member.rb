module Fd
  class Member < ApplicationRecord
    self.table_name = "fd.member"
    self.primary_key = "user_id"

    has_one :identity, class_name: "Fd::MemberIdentity", foreign_key: :user_id,
      inverse_of: :member, dependent: nil

    MIN_TERM = 3
    LIMIT = 8

    scope :live, -> { where(is_deleted: false, is_bot: false) }

    def readonly?
      persisted?
    end

    def name
      display_name.presence || handle.presence || "@#{user_id}"
    end

    def initial
      first = name.sub(/\A@/, "").strip
      first.present? ? first[0].upcase : "?"
    end
  end
end
