class Authz
  class Unknown < ArgumentError; end

  PATH = Rails.root.join("../db/capabilities.yml").freeze
  TABLE = YAML.load_file(PATH).freeze

  CAPABILITIES = TABLE.fetch("capabilities").freeze
  ROLES = TABLE.fetch("roles").freeze
  AREAS = TABLE.fetch("areas").freeze
  SCOPES = TABLE.fetch("record_scopes").map(&:to_sym).freeze

  HELD = "SELECT capability, via FROM app.effective_capability WHERE user_id = ?".freeze

  class << self
    def keys = CAPABILITIES.keys

    def fetch(key)
      CAPABILITIES.fetch(key.to_s) { raise Unknown, "#{key} is not a capability" }
    end

    def label(key) = fetch(key).fetch("label")

    def area(key) = AREAS.fetch(fetch(key).fetch("area"))

    def record_scope(key) = fetch(key)["record_scope"]&.to_sym

    def scoped?(key) = record_scope(key).present?

    def logged?(key) = fetch(key)["logged"] == true

    def every_account?(key) = fetch(key)["every_account"] == true

    def locked?(key) = fetch(key)["locked"] == true

    def events(key) = fetch(key)["events"] || []

    def role_names = ROLES.keys

    def role_label(role) = ROLES.fetch(role.to_s).fetch("label")

    def grantable_roles = ROLES.select { |_, one| one.fetch("grantable", true) }.keys

    def superadmin?(role) = ROLES.fetch(role.to_s, {})["everything"] == true

    def baseline(role)
      one = ROLES.fetch(role.to_s, {})
      return keys if one["everything"]

      one["capabilities"] || []
    end

    def by_area
      keys.group_by { |key| area(key) }
    end

    ROLES_HELD = "SELECT role FROM app.effective_role WHERE user_id = ? ORDER BY role".freeze

    WHO_HOLDS = "SELECT DISTINCT user_id FROM app.effective_capability " \
                "WHERE capability = ? ORDER BY user_id".freeze

    def held(user_id)
      return {} if user_id.blank?

      cache = Current.effective_capabilities ||= {}
      cache[user_id] ||= load_held(user_id)
    end

    def roles_held(user_id)
      return [] if user_id.blank?

      cache = Current.held_roles ||= {}
      cache[user_id] ||= ApplicationRecord.connection
        .select_values(ApplicationRecord.sanitize_sql([ROLES_HELD, user_id]))
    end

    def role?(account, role)
      return false if account.nil?

      roles_held(account.user_id).include?(role.to_s)
    end

    def everything?(account)
      return false if account.nil?

      roles_held(account.user_id).any? { |role| superadmin?(role) }
    end

    def anything?(account)
      return false if account.nil?

      roles_held(account.user_id).any? || held(account.user_id).any?
    end

    def who_holds(key)
      ApplicationRecord.connection.select_values(
        ApplicationRecord.sanitize_sql([WHO_HOLDS, key.to_s])
      )
    end

    def holds?(account, key)
      return false if account.nil?
      return true if every_account?(key)

      held(account.user_id).key?(key.to_s)
    end

    def via(account, key)
      return nil if account.nil?

      held(account.user_id)[key.to_s]
    end

    def may?(account, key, record = nil)
      return false unless holds?(account, key)

      within_scope?(account, key, record)
    end

    def within_scope?(account, key, record)
      scope = record_scope(key)
      return true if scope.nil? || record.nil?

      case scope
      when :author then record.respond_to?(:author) && record.author == account.user_id
      when :channel then Channels::Audience.may_see?(account, record)
      else false
      end
    end

    def why_not(account, key, record = nil)
      return nil if may?(account, key, record)
      return "you hold no access" if account.nil? || held(account.user_id).empty?
      return refusal(key) unless holds?(account, key)

      "that is not yours"
    end

    # name the roles the catalogue gives it to, ordinary ones before superadmins
    def refusal(key)
      said = label(key).downcase
      ordinary, supers = role_names.partition { |role| !superadmin?(role) }
      carried = ordinary.select { |role| baseline(role).include?(key) }
      carried = supers.select { |role| baseline(role).include?(key) } if carried.empty?
      return "#{said} is not yours to use" if carried.empty?

      "#{said} is #{carried.map { |role| role_label(role) }.to_sentence} only"
    end

    def load_held(user_id)
      rows = ApplicationRecord.connection.select_all(
        ApplicationRecord.sanitize_sql([HELD, user_id])
      )
      rows.to_h { |row| [row["capability"], row["via"]] }
    end
  end
end
