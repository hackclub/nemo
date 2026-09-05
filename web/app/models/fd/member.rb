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

    TERM_FIELDS = %w[user_id display_name handle title].freeze
    IDENTITY_TERM_FIELDS = %w[real_name first_name last_name email].freeze

    def self.search(term, actor: nil, limit: LIMIT)
      term = term.to_s.strip.delete_prefix("@")
      return where(user_id: term.upcase).limit(1) if term.match?(MEMBER_ID) && exists?(user_id: term.upcase)
      return none if term.length < MIN_TERM

      like = "%#{sanitize_sql_like(term)}%"
      fields = TERM_FIELDS.map { |field| "#{table_name}.#{field} ILIKE :q" }
      if actor&.may?("identity.read")
        fields += IDENTITY_TERM_FIELDS.map { |field| "fd.member_identity.#{field} ILIKE :q" }
      end
      left_joins(:identity).where(fields.join(" OR "), q: like).by_name.limit(limit)
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
