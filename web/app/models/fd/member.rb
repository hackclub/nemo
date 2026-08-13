module Fd
  class Member < ApplicationRecord
    self.table_name = "fd.member"
    self.primary_key = "user_id"

    has_one :identity, class_name: "Fd::MemberIdentity", foreign_key: :user_id,
      inverse_of: :member, dependent: nil

    scope :live, -> { where(is_deleted: false, is_bot: false) }
    scope :by_name, -> { order(Arel.sql("lower(display_name)")) }

    def readonly?
      persisted?
    end

    def name
      display_name.presence || handle.presence || "@#{user_id}"
    end
  end
end
