module Analytics
  class MartNewcomerChannels < ApplicationRecord
    self.table_name = "analytics.mart_newcomer_channels"

    DEFAULT_COHORT = "last30".freeze

    MEASURES = {
      "first" => { label: "posted here first", rank: :newcomer_first_posts,
                   gate: :newcomer_first_posts },
      "posting" => { label: "posted here", rank: :newcomers_posting, gate: :newcomers_posting },
      "returning" => { label: "came back", rank: :newcomers_returning, gate: :newcomers_posting },
      "joined" => { label: "joined", rank: :newcomers_joined, gate: :newcomers_joined }
    }.freeze

    DEFAULT_MEASURE = "first".freeze

    Cohort = Struct.new(:key, :order, :starts_on, :ends_on, :mature, :size, keyword_init: true) do
      def default? = key == DEFAULT_COHORT

      def label
        default? ? "Last 30 days" : ends_on.strftime("%b %Y")
      end

      def window
        default? ? "30 days to #{ends_on.strftime("%-d %b %Y")}" : ends_on.strftime("%B %Y")
      end
    end

    scope :for_cohort, ->(key) { where(cohort_key: key) }

    def readonly?
      true
    end

    def self.measure(key)
      MEASURES.key?(key.to_s) ? key.to_s : DEFAULT_MEASURE
    end

    MONTHS_OFFERED = 12

    def self.cohorts
      distinct
        .order(:cohort_order, cohort_end: :desc)
        .pluck(:cohort_key, :cohort_order, :cohort_start, :cohort_end, :mature, :cohort_size)
        .map do |key, order, starts_on, ends_on, mature, size|
          Cohort.new(key: key, order: order, starts_on: starts_on, ends_on: ends_on,
            mature: mature, size: size.to_i)
        end
        .group_by(&:default?)
        .then { |held| held.fetch(true, []) + held.fetch(false, []).first(MONTHS_OFFERED) }
    end

    def self.cohort(key)
      asked = key.to_s
      cohorts.find { |c| c.key == asked } || cohorts.find(&:default?) || cohorts.first
    end

    def self.ranked(key, floor:, cohort: DEFAULT_COHORT, limit: 10)
      said = MEASURES.fetch(measure(key))
      for_cohort(cohort)
        .where(said[:gate] => floor..)
        .where(said[:rank] => 1..)
        .order(said[:rank] => :desc, newcomer_messages: :desc)
        .limit(limit)
    end
  end
end
