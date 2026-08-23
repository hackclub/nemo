module Fd
  class Permission
    class Unknown < ArgumentError; end

    PATH = Rails.root.join("../db/permissions.yml").freeze
    TABLE = YAML.load_file(PATH).freeze

    ROLES = TABLE.fetch("roles").freeze
    ROLE_LABELS = TABLE.fetch("role_labels").freeze
    ROLE_SETS = TABLE.fetch("role_sets").transform_values(&:freeze).freeze

    EVERYONE = ROLE_SETS.fetch("everyone")
    LEAD = ROLE_SETS.fetch("lead")
    MANAGER = ROLE_SETS.fetch("manager")
    SCOPES = %i[assigned author].freeze

    AREAS = TABLE.fetch("areas").freeze

    ALL = TABLE.fetch("permissions").to_h { |key, row|
      [key, {
        label: row.fetch("label"),
        roles: ROLE_SETS.fetch(row.fetch("held_by")),
        scope: row["scope"]&.to_sym,
        events: (row["events"] || []).freeze,
        logged: row["logged"] == true
      }.freeze]
    }.freeze

    LOCKED = TABLE.fetch("locked").freeze

    def self.keys = ALL.keys

    def self.fetch(key)
      ALL.fetch(key.to_s) { raise Unknown, "#{key} is not a permission" }
    end

    def self.label(key) = fetch(key)[:label]

    def self.default_roles(key) = fetch(key)[:roles]

    def self.roles(key)
      moved = Current.role_permissions
      return default_roles(key) if moved.empty?

      held = default_roles(key)
      ROLES.select { |role| moved.fetch([role, key.to_s]) { held.include?(role) } }
    end

    def self.scope(key) = fetch(key)[:scope]

    def self.events(key) = fetch(key)[:events]

    def self.logged?(key) = fetch(key)[:logged] == true

    def self.locked?(key) = LOCKED.include?(key.to_s)

    def self.area(key) = AREAS.fetch(key.to_s.split(".").first)

    def self.held_by(role) = keys.select { |key| roles(key).include?(role.to_s) }

    def self.lead_only = keys.reject { |key| roles(key).include?("firefighter") }

    def self.manager_only = keys.select { |key| roles(key) == MANAGER }

    def self.by_area
      keys.group_by { |key| area(key) }
    end

    def self.least(key)
      ROLES.find { |role| roles(key).include?(role) }
    end

    def self.refusal(key)
      return "you cannot make that change" unless ALL.key?(key.to_s)
      return "that is not yours" if least(key) == "firefighter"

      "#{label(key).downcase} is #{ROLE_LABELS.fetch(least(key)).downcase} only"
    end
  end
end
