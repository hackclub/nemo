module Community
  class Permission
    class Unknown < ArgumentError; end

    PATH = Rails.root.join("../db/community_permissions.yml").freeze
    TABLE = YAML.load_file(PATH).freeze

    FAMILIES = TABLE.fetch("families").freeze
    ROLE_LABELS = TABLE.fetch("role_labels").freeze
    SUPERADMIN = TABLE.fetch("superadmin").freeze
    AREAS = TABLE.fetch("areas").freeze

    LADDERS = FAMILIES.transform_values { |row| row.fetch("roles").freeze }.freeze

    ALL = TABLE.fetch("permissions").to_h { |key, row|
      [key, { label: row.fetch("label"), least: row.fetch("least") }.freeze]
    }.freeze

    def self.keys = ALL.keys

    def self.families = FAMILIES.keys

    def self.roles(family) = LADDERS.fetch(family.to_s)

    def self.every_role = LADDERS.values.flatten

    def self.family_of(role)
      LADDERS.find { |_family, roles| roles.include?(role.to_s) }&.first
    end

    def self.family_label(family) = FAMILIES.fetch(family.to_s).fetch("label")

    def self.role_label(role) = ROLE_LABELS.fetch(role.to_s, role.to_s)

    def self.superadmin(family) = SUPERADMIN.fetch(family.to_s)

    def self.fetch(key)
      ALL.fetch(key.to_s) { raise Unknown, "#{key} is not a community permission" }
    end

    def self.label(key) = fetch(key)[:label]

    def self.least(key) = fetch(key)[:least]

    def self.family(key) = family_of(least(key))

    def self.area(key) = AREAS.fetch(key.to_s.split(".").first)

    def self.by_area = keys.group_by { |key| area(key) }

    def self.holds?(role, key)
      return false if role.blank?

      ladder = roles(family(key))
      held = ladder.index(role.to_s)
      return false if held.nil?

      held >= ladder.index(least(key))
    end

    def self.held_by(role)
      keys.select { |key| holds?(role, key) }
    end

    def self.refusal(key)
      "#{label(key).downcase} is #{role_label(least(key)).downcase} only"
    end
  end
end
