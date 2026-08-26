module Analytics
  class MartNewcomerChannels < ApplicationRecord
    self.table_name = "analytics.mart_newcomer_channels"

    MEASURES = {
      "posting" => { label: "posted here", rank: :newcomers_posting, gate: :newcomers_posting },
      "returning" => { label: "came back", rank: :newcomers_returning, gate: :newcomers_posting },
      "first" => { label: "posted here first", rank: :newcomer_first_posts, gate: :newcomers_posting },
      "joined" => { label: "joined", rank: :newcomers_joined, gate: :newcomers_joined }
    }.freeze

    DEFAULT_MEASURE = "posting".freeze

    def readonly?
      true
    end

    def self.measure(key)
      MEASURES.key?(key.to_s) ? key.to_s : DEFAULT_MEASURE
    end

    def self.ranked(key, floor:, limit: 10)
      said = MEASURES.fetch(measure(key))
      where(said[:gate] => floor..)
        .where(said[:rank] => 1..)
        .order(said[:rank] => :desc, newcomer_messages: :desc)
        .limit(limit)
    end
  end
end
