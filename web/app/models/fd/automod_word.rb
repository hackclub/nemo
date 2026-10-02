module Fd
  class AutomodWord < ApplicationRecord
    self.table_name = "fd.automod_words"

    WORD = "word".freeze
    SUBSTRING = "substring".freeze
    REGEX = "regex".freeze
    MATCHES = [WORD, SUBSTRING, REGEX].freeze

    FLAG = "flag".freeze
    WARN = "warn".freeze
    DELETE = "delete".freeze
    EFFECTS = [FLAG, WARN, DELETE].freeze

    SHIPPED_EFFECTS = [FLAG].freeze

    has_many :matches, class_name: "Fd::AutomodMatch", foreign_key: :word_id,
      inverse_of: :watch, dependent: :nullify

    scope :active, -> { where(active: true) }
    scope :retired, -> { where(active: false) }
    scope :newest_first, -> { order(added_at: :desc, id: :desc) }

    def self.watching = active.newest_first.to_a

    def self.add!(word:, by:, match_mode: WORD, effect: FLAG, category_key: nil, note: nil)
      create!(word: word.to_s.strip, match_mode: match_mode, effect: effect,
        category_key: category_key.presence, note: note.presence, added_by: by)
    end

    def retire!(by:)
      update!(active: false, retired_at: Time.current, retired_by: by)
    end

    def retired? = !active

    def people_named
      [added_by, retired_by].compact
    end
  end
end
