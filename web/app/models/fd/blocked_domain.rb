module Fd
  class BlockedDomain < ApplicationRecord
    self.table_name = "fd.blocked_domains"

    EXACT = "exact".freeze
    SUFFIX = "suffix".freeze
    MATCHES = [EXACT, SUFFIX].freeze

    FLAG = "flag".freeze
    HOLD = "hold".freeze
    DEACTIVATE = "deactivate".freeze
    EFFECTS = [FLAG, HOLD, DEACTIVATE].freeze
    SHIPPED_EFFECTS = [FLAG].freeze

    SHAPE = /\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/
    TOO_MANY = 0.005

    scope :active, -> { where(active: true) }
    scope :retired, -> { where(active: false) }
    scope :newest_first, -> { order(added_at: :desc, id: :desc) }

    def self.watching = active.newest_first.to_a

    def self.add!(domain:, by:, match_mode: EXACT, effect: FLAG, note: nil)
      create!(domain: domain.to_s.strip.downcase.delete_prefix("@"),
        match_mode: match_mode, effect: effect, note: note.presence, added_by: by)
    end

    def self.holds(domain)
      said = domain.to_s.strip.downcase
      return [] if said.blank?

      active.select { |one| one.holds?(said) }
    end

    def self.worst_for(domain)
      holds(domain).max_by { |one| EFFECTS.index(one.effect) }
    end

    def self.shape?(said)
      said.to_s.strip.downcase.delete_prefix("@").match?(SHAPE)
    end

    def self.people_on(domain, match_mode: EXACT)
      said = domain.to_s.strip.downcase
      scope = MemberIdentity.kept.where.not(email: nil)
      return scope.where("lower(split_part(email, '@', 2)) = ?", said).count if
        match_mode == EXACT

      scope.where("lower(split_part(email, '@', 2)) = ? OR " \
                  "lower(split_part(email, '@', 2)) LIKE ?", said, "%.#{said}").count
    end

    def self.too_many?(count)
      known = MemberIdentity.kept.where.not(email: nil).count
      return false if known.zero?

      count.to_f / known > TOO_MANY
    end

    def holds?(said)
      return said == domain if match_mode == EXACT

      said == domain || said.end_with?(".#{domain}")
    end

    def retire!(by:)
      update!(active: false, retired_at: Time.current, retired_by: by)
    end

    def retired? = !active

    def shipped? = SHIPPED_EFFECTS.include?(effect)

    def people_here
      @people_here ||= self.class.people_on(domain, match_mode: match_mode)
    end

    def people_named = [added_by, retired_by].compact
  end
end
