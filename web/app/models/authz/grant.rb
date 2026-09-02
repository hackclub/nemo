class Authz
  class Grant < ApplicationRecord
    class NotAllowed < StandardError; end

    self.table_name = "app.grant"

    KINDS = %w[role capability].freeze
    EFFECTS = %w[allow deny].freeze

    scope :live, -> { where(revoked_at: nil) }
    scope :roles, -> { where(kind: "role") }
    scope :capabilities, -> { where(kind: "capability") }
    scope :for_person, ->(user_id) { where(user_id: user_id) }
    scope :newest_first, -> { order(granted_at: :desc, id: :desc) }

    def self.give!(user_id, kind:, name:, by:, effect: "allow", reason: nil)
      refuse "#{kind} is not a kind of grant" unless KINDS.include?(kind.to_s)
      refuse "#{effect} is not an effect" unless EFFECTS.include?(effect.to_s)
      check!(kind.to_s, name.to_s, effect.to_s)

      transaction do
        Staff.find_or_create_by!(user_id: user_id)
        live.for_person(user_id).where(kind: kind, name: name).find_each do |held|
          held.take_back!(by: by)
        end
        live.for_person(user_id).roles.find_each { |held| held.take_back!(by: by) } if
          kind.to_s == "role"
        create!(user_id: user_id, kind: kind, name: name, effect: effect,
          granted_by: by, granted_at: Time.current, reason: reason.presence)
      end
    end

    def self.check!(kind, name, effect)
      if kind == "role"
        refuse "#{name} is not a role" unless Authz.role_names.include?(name)
        refuse "#{name} is not a grantable role" unless Authz.grantable_roles.include?(name)
        refuse "a role cannot be denied" unless effect == "allow"
      else
        refuse "#{name} is not a capability" unless Authz.keys.include?(name)
        refuse "#{Authz.label(name)} cannot be handed out" if Authz.locked?(name)
      end
    end

    def self.take_back_all!(user_id, by:)
      live.for_person(user_id).find_each { |held| held.take_back!(by: by) }
    end

    def take_back!(by:, at: Time.current)
      refuse "that grant already ended" if revoked?

      update!(revoked_by: by, revoked_at: at)
    end

    def live? = revoked_at.nil?

    def revoked? = !live?

    def role? = kind == "role"

    def denial? = effect == "deny"

    def label
      role? ? Authz.role_label(name) : Authz.label(name)
    end

    def self.refuse(why)
      raise NotAllowed, why
    end

    def refuse(why)
      self.class.refuse(why)
    end
  end
end
