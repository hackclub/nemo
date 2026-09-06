module Fd
  class Member < ApplicationRecord
    self.table_name = "fd.member"
    self.primary_key = "user_id"

    has_one :identity, class_name: "Fd::MemberIdentity", foreign_key: :user_id,
      inverse_of: :member, dependent: nil

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/i
    MIN_TERM = 2
    LIMIT = 8

    scope :live, -> { where(is_deleted: false, is_bot: false) }
    scope :by_name, -> { order(Arel.sql("lower(coalesce(nullif(display_name, ''), handle))")) }

    TERM_FIELDS = %w[display_name handle].freeze
    IDENTITY_TERM_FIELDS = %w[real_name first_name last_name email].freeze

    def self.search(term, actor: nil, limit: LIMIT)
      term = term.to_s.strip.delete_prefix("@")
      return where(user_id: term.upcase).limit(1) if term.match?(MEMBER_ID) && exists?(user_id: term.upcase)
      return none if term.length < MIN_TERM

      like = "%#{sanitize_sql_like(term.downcase)}%"
      identity = actor&.may?("identity.read")
      joined = left_joins(:identity)
      hits = joined.where(user_id: named(like))
      hits = hits.or(joined.where(user_id: identified(like))) if identity
      hits.order(Arel.sql(match_rank(term, identity)), :is_deleted, :is_bot)
        .by_name.limit(limit)
    end

    def self.named(like)
      unscoped.where(lower_like(arel_table, TERM_FIELDS, like)).select(:user_id)
    end

    def self.identified(like)
      MemberIdentity.unscoped
        .where(lower_like(MemberIdentity.arel_table, IDENTITY_TERM_FIELDS, like))
        .select(:user_id)
    end

    def self.lower_like(table, fields, like)
      fields
        .map { |field| Arel::Nodes::NamedFunction.new("lower", [table[field]]).matches(like, nil, true) }
        .reduce(:or)
    end

    UNIQUE_FIELDS = %W[#{table_name}.handle #{table_name}.user_id].freeze
    RANKED_FIELDS = %W[#{table_name}.display_name #{table_name}.handle #{table_name}.user_id].freeze
    IDENTITY_RANKED_FIELDS = %w[fd.member_identity.real_name fd.member_identity.email].freeze

    def self.match_rank(term, identity)
      tiers = [[UNIQUE_FIELDS, :exact], [RANKED_FIELDS, :exact], [RANKED_FIELDS, :starts]]
      tiers.insert(2, [IDENTITY_RANKED_FIELDS, :exact]) if identity
      tiers << [IDENTITY_RANKED_FIELDS, :starts] if identity
      whens = tiers.each_with_index.map do |(fields, how), rank|
        test = fields.map do |field|
          how == :exact ? "lower(coalesce(#{field}, '')) = :exact" : "lower(#{field}) LIKE :starts"
        end
        "WHEN #{test.join(' OR ')} THEN #{rank}"
      end
      sanitize_sql_array([
        "CASE #{whens.join(' ')} ELSE #{tiers.size} END",
        { exact: term.downcase, starts: "#{sanitize_sql_like(term.downcase)}%" }
      ])
    end

    def readonly?
      persisted?
    end

    def name
      display_name.presence || handle.presence || "@#{user_id}"
    end

    def initial
      first = name.sub(/\A@/, "").strip
      first.present? ? first[0].upcase : "?"
    end
  end
end
