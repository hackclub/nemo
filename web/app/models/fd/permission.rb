module Fd
  class Permission
    class Unknown < ArgumentError; end

    ROLES = %w[firefighter lead community_manager].freeze
    ROLE_LABELS = { "firefighter" => "Firefighter", "lead" => "Lead",
                    "community_manager" => "Community manager" }.freeze

    EVERYONE = ROLES
    LEAD = %w[lead community_manager].freeze
    MANAGER = %w[community_manager].freeze
    SCOPES = %i[assigned author].freeze

    AREAS = { "case" => "Cases", "decision" => "Decisions", "member" => "People and access",
              "identity" => "People and access", "access" => "People and access" }.freeze

    ALL = {
      "case.read" => {
        label: "Read every case, note and thread", roles: EVERYONE, events: []
      },
      "case.open" => {
        label: "Open a case, claim it, hand it back", roles: EVERYONE,
        events: %w[case/opened assignee/claimed assignee/unclaimed]
      },
      "case.note" => {
        label: "Write a note, delete their own", roles: EVERYONE, scope: :author,
        events: %w[note/noted note/deleted]
      },
      "case.people" => {
        label: "Add somebody, take somebody off", roles: EVERYONE, scope: :assigned,
        events: %w[participant/attached participant/detached]
      },
      "case.thread" => {
        label: "Attach a thread, flag a message", roles: EVERYONE, scope: :assigned,
        events: %w[thread/attached thread/detached citation/flagged citation/unflagged]
      },
      "case.act" => {
        label: "Log an action against somebody", roles: EVERYONE, scope: :assigned,
        events: %w[action/performed]
      },
      "case.resolve" => {
        label: "Resolve a case, mark a duplicate", roles: EVERYONE, scope: :assigned,
        events: %w[case/resolved]
      },
      "case.reverse" => {
        label: "Reverse an action somebody logged", roles: EVERYONE, scope: :assigned,
        events: %w[action/reversed]
      },
      "case.reopen" => {
        label: "Put a resolved case back in the queue", roles: EVERYONE, scope: :assigned,
        events: %w[case/reopened]
      },
      "decision.write" => {
        label: "Propose one, reword any of them, drop their own", roles: EVERYONE,
        events: %w[decision/proposed decision/amended decision/dropped]
      },
      "decision.link" => {
        label: "Link threads, link a case to a decision", roles: EVERYONE,
        events: %w[decision_thread/attached decision_thread/detached case/followed
                   case/unfollowed]
      },
      "decision.settle" => {
        label: "Settle a proposal, putting it in force", roles: LEAD,
        events: %w[decision/settled]
      },
      "decision.retire" => {
        label: "Supersede or retire a rule", roles: LEAD,
        events: %w[decision/superseded]
      },
      "member.note" => {
        label: "Write a standing note about a member", roles: EVERYONE, events: []
      },
      "identity.read" => {
        label: "See the real name and email behind an id", roles: EVERYONE, events: [],
        logged: true
      },
      "access.read" => {
        label: "See who holds access and what they did with it", roles: MANAGER, events: []
      },
      "access.grant" => {
        label: "Give or take back access", roles: MANAGER,
        events: %w[grant/granted grant/revoked permission/granted permission/revoked]
      }
    }.freeze

    LOCKED = %w[access.grant].freeze

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
