module Community
  class Grant < ApplicationRecord
    self.table_name = "app.community_grants"

    class NotAllowed < StandardError; end

    scope :live, -> { where(revoked_at: nil) }
    scope :ended, -> { where.not(revoked_at: nil) }
    scope :newest_first, -> { order(granted_at: :desc, id: :desc) }
    scope :of_family, ->(family) { where(family: family.to_s) }
    scope :for_person, ->(user_id) { where(user_id: user_id) }

    def self.role_for(user_id, family)
      live.of_family(family).where(user_id: user_id).pick(:role)
    end

    def self.held_by(user_id)
      live.where(user_id: user_id).pluck(:family, :role).to_h
    end

    def self.roles_for(user_ids, family)
      live.of_family(family).where(user_id: user_ids).pluck(:user_id, :role).to_h
    end

    def self.give!(user_id, role:, by:, reason: nil, at: Time.current)
      family = Permission.family_of(role)
      refuse "#{role} is not a community role" if family.nil?

      transaction do
        Staff.find_or_create_by!(user_id: user_id)
        live.of_family(family).where(user_id: user_id)
          .find_each { |held| held.take_back!(by: by, at: at) }
        create!(user_id: user_id, family: family, role: role.to_s, granted_by: by,
          granted_at: at, reason: reason.presence)
      end
    end

    def self.take_back!(user_id, family:, by:, at: Time.current)
      live.of_family(family).where(user_id: user_id)
        .find_each { |held| held.take_back!(by: by, at: at) }
    end

    def take_back!(by:, at: Time.current)
      raise NotAllowed, "that grant already ended" if revoked?

      update!(revoked_by: by, revoked_at: at)
    end

    def live? = revoked_at.nil?

    def revoked? = !live?

    def label = Permission.role_label(role)

    def self.refuse(why)
      raise NotAllowed, why
    end
  end
end
