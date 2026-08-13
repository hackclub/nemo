module Fd
  class MemberIdentity < ApplicationRecord
    class NoActor < ArgumentError; end

    self.table_name = "fd.member_identity"
    self.primary_key = "user_id"

    belongs_to :member, class_name: "Fd::Member", foreign_key: :user_id, inverse_of: :identity

    scope :kept, -> { where(purged_at: nil) }

    def self.look_up(user_id, actor:)
      raise NoActor, "reading identity needs an actor to log it against" if actor.nil?

      row = kept.find_by(user_id: user_id)
      AccessLog.record!(actor: actor, subject_user_id: user_id, field_class: "identity")
      row
    end

    def readonly?
      persisted?
    end

    def purged?
      purged_at.present?
    end
  end
end
