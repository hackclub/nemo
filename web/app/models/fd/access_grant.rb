module Fd
  class AccessGrant < ApplicationRecord
    self.table_name = "fd.access_grants"

    class NotAllowed < StandardError; end

    scope :live, -> { where(revoked_at: nil) }
    scope :ended, -> { where.not(revoked_at: nil) }
    scope :newest_first, -> { order(granted_at: :desc, id: :desc) }
    scope :of_role, ->(role) { where(role: role) }
    scope :for_person, ->(user_id) { where(user_id: user_id) }

    def self.role_for(user_id)
      live.where(user_id: user_id).pick(:role)
    end

    def self.roles_for(user_ids)
      live.where(user_id: user_ids).pluck(:user_id, :role).to_h
    end

    def self.give!(user_id, role:, by:, reason: nil, at: Time.current)
      refuse "#{role} is not a role" unless Permission::ROLES.include?(role.to_s)

      transaction do
        Staff.find_or_create_by!(user_id: user_id)
        live.where(user_id: user_id).find_each { |held| held.take_back!(by: by, at: at) }
        create!(user_id: user_id, role: role, granted_by: by, granted_at: at,
          reason: reason.presence)
      end
    end

    def take_back!(by:, at: Time.current)
      refuse "that grant already ended" if revoked?

      update!(revoked_by: by, revoked_at: at)
    end

    def live? = revoked_at.nil?

    def revoked? = !live?

    def held_for(now = Time.current)
      (revoked_at || now) - granted_at
    end

    def self.refuse(why)
      raise NotAllowed, why
    end

    def refuse(why)
      self.class.refuse(why)
    end
  end
end
