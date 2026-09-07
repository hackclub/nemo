module Journey
  class Lifecycle
    Row = Struct.new(
      :month, :invited, :claimed, :searched, :posted_30d, :median_days,
      :claim_rate_30d, :claim_dates_complete, :claim_settles_on,
      :measured_30, :retained_30, :rate_30,
      :measured_90, :retained_90, :rate_90, :day_90_mature,
      keyword_init: true
    ) do
      def claimed_within_30d
        return nil if claim_rate_30d.nil?

        (claim_rate_30d.to_f * invited.to_i).round
      end

      def posted_rate_30d
        return nil if searched.to_i.zero?

        posted_30d.to_f / searched
      end

      def closes_on(stage)
        base = month.end_of_month
        stage == :rate_90 ? base + 90 : base + 30
      end
    end

    STAGES = [
      { key: :claim_rate_30d, head: "claimed in 30 days" },
      { key: :posted_rate_30d, head: "posted in 30 days" },
      { key: :rate_30, head: "active at day 30" },
      { key: :rate_90, head: "active at day 90" }
    ].freeze

    def self.recent(limit)
      cohorts = Analytics::MartMonthlyCohorts.order(cohort_month: :desc).limit(limit).to_a
      return [] if cohorts.empty?

      months = cohorts.map(&:cohort_month)
      growth = Analytics::MartGrowth.where(month: months).index_by(&:month)
      retention = Analytics::MartCohortRetention.where(cohort_month: months).index_by(&:cohort_month)

      cohorts.map { |c| build(c, growth[c.cohort_month], retention[c.cohort_month]) }
    end

    def self.build(cohort, growth, retention)
      Row.new(
        month: cohort.cohort_month,
        invited: growth&.invited_members || cohort.members,
        claimed: cohort.members,
        searched: cohort.searched,
        posted_30d: cohort.posted_within_30d,
        median_days: cohort.median_days_to_first_post,
        claim_rate_30d: growth&.claim_rate_30d,
        claim_dates_complete: growth&.claim_dates_complete,
        claim_settles_on: growth&.claim_rate_30d_final_on,
        measured_30: retention&.measured_day_30.to_i,
        retained_30: retention&.retained_day_30.to_i,
        rate_30: retention&.retained_day_30_rate,
        measured_90: retention&.measured_day_90.to_i,
        retained_90: retention&.retained_day_90.to_i,
        rate_90: retention&.retained_day_90_rate,
        day_90_mature: retention&.day_90_mature
      )
    end
    private_class_method :build
  end
end
