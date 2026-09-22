module Fd
  class Member < ApplicationRecord
    self.table_name = "fd.member"
    self.primary_key = "user_id"

    has_one :identity, class_name: "Fd::MemberIdentity", foreign_key: :user_id,
      inverse_of: :member, dependent: nil
    has_one :cachet, class_name: "CachetProfile", foreign_key: :user_id, dependent: nil

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/i
    MIN_TERM = 3
    LIMIT = 8
    SHORTLIST = 60

    scope :live, -> { where(is_deleted: false, is_bot: false) }
    scope :by_name, -> {
      order(Arel.sql("lower(coalesce(nullif(fd.member.display_name, ''), fd.member.handle))"), :user_id)
    }

    TERM_FIELDS = %w[display_name handle].freeze
    CACHET_TERM_FIELDS = %w[display_name].freeze
    IDENTITY_TERM_FIELDS = %w[real_name first_name last_name email].freeze

    HOW_BUSY = <<~SQL.squish.freeze
      LEFT JOIN LATERAL (
        SELECT messages_posted FROM analytics.fct_member_window busy
        WHERE busy.source = '#{Analytics::MemberWindow::LIFETIME_SOURCE}'
          AND busy.user_id = fd.member.user_id
        LIMIT 1
      ) spoke ON true
    SQL

    SAID_MOST = "spoke.messages_posted DESC NULLS LAST".freeze

    def self.search(term, actor: nil, limit: LIMIT, live_only: false, case_id: nil, bots: false)
      term = term.to_s.strip.delete_prefix("@")
      return where(user_id: term.upcase).limit(1) if term.match?(MEMBER_ID) && exists?(user_id: term.upcase)
      return none if term.length < MIN_TERM

      near = shortlist(term, actor: actor, live_only: live_only, bots: bots)
      joins("JOIN (#{near.to_sql}) pick ON pick.user_id = #{table_name}.user_id")
        .order(Arel.sql(closest(case_id))).by_name.limit(limit)
    end

    def self.shortlist(term, actor:, live_only:, bots: false)
      like = "%#{sanitize_sql_like(term.downcase)}%"
      identity = actor&.may?("identity.read")
      hits = left_joins(:identity, :cachet).joins(HOW_BUSY)
        .where(arel_table[:user_id].in(anybody(like, identity)))
      hits = hits.where(is_deleted: false, is_bot: bots) if live_only
      place = MemberMatch.ranked(term, identity: identity, columns: COLUMNS)
      hits.select(Arel.sql("#{table_name}.user_id, #{place} AS place, spoke.messages_posted AS talked"))
        .order(Arel.sql(place), :is_deleted, :is_bot, Arel.sql(SAID_MOST))
        .by_name.limit(SHORTLIST)
    end

    def self.anybody(like, identity)
      ways = [named(like), shown_as(like)]
      ways << identified(like) if identity
      ways.map(&:arel).reduce { |left, right| Arel::Nodes::Union.new(left, right) }
    end

    def self.closest(case_id)
      ["pick.place", on_the_case(case_id), "#{table_name}.is_deleted", "#{table_name}.is_bot",
       "pick.talked DESC NULLS LAST"].compact.join(", ")
    end

    def self.on_the_case(case_id)
      return nil if case_id.blank?

      sanitize_sql_array(["(EXISTS (SELECT 1 FROM fd.case_participants party " \
        "WHERE party.user_id = #{table_name}.user_id AND party.case_id = ?)) DESC", case_id])
    end

    def self.named(like)
      unscoped.where(lower_like(arel_table, TERM_FIELDS, like)).select(:user_id)
    end

    def self.shown_as(like)
      CachetProfile.unscoped
        .where(lower_like(CachetProfile.arel_table, CACHET_TERM_FIELDS, like))
        .select(:user_id)
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

    COLUMNS = {
      handle: "#{table_name}.handle",
      user_id: "#{table_name}.user_id",
      display_name: "#{table_name}.display_name",
      shown_name: "app.cachet_profiles.display_name",
      real_name: "fd.member_identity.real_name",
      email: "fd.member_identity.email"
    }.freeze

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
