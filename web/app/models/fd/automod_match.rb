module Fd
  class AutomodMatch < ApplicationRecord
    self.table_name = "fd.automod_matches"

    belongs_to :watch, class_name: "Fd::AutomodWord", foreign_key: :word_id,
      optional: true, inverse_of: :matches

    scope :newest_first, -> { order(at: :desc, id: :desc) }

    def people_named
      [user_id].compact
    end
  end
end
