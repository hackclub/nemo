module Journey
  class Lifecycle
    Row = Struct.new(
      :month, :invited, :claimed, :searched, :posted_30d, :median_days,
      :claim_rate_30d, :claim_dates_complete, :claim_settles_on,
      :first_posters,
      :measured_30, :retained_30, :rate_30,
      :measured_90, :retained_90, :rate_90, :day_90_mature,
      keyword_init: true
    ) do
      def claimed_within_30d
        return nil if claim_rate_30d.nil?

        (claim_rate_30d.to_f * invited.to_i).round
      end

      def signed_rate
        return nil if invited.to_i.zero?

        claimed.to_f / invited
      end

      def posted_rate_30d
        return nil if invited.to_i.zero? || searched.to_i.zero?

        posted_30d.to_f / invited
      end

      def searched_share
        return nil if claimed.to_i.zero?

        searched.to_f / claimed
      end

      def cover_30
        return nil if first_posters.to_i.zero?

        measured_30.to_f / first_posters
      end

      def cover_90
        return nil if first_posters.to_i.zero?

        measured_90.to_f / first_posters
      end

      def funnel_30
        return nil if invited.to_i.zero? || (cover_30 || 0) < Lifecycle::COVER_FLOOR

        retained_30.to_f / invited
      end

      def funnel_90
        return nil if invited.to_i.zero? || (cover_90 || 0) < Lifecycle::COVER_FLOOR

        retained_90.to_f / invited
      end

      def step_of(stage)
        return nil if public_send(stage[:key]).nil?

        before = public_send(stage[:prev]).to_i
        return nil if before.zero?

        public_send(stage[:num]).to_f / before
      end

      def closes_on(stage)
        base = month.end_of_month
        stage == :funnel_90 ? base + 90 : base + 30
      end
    end

    COVER_FLOOR = 0.9

    STAGES = [
      { key: :signed_rate, head: "signed in", num: :claimed, prev: :invited },
      { key: :posted_rate_30d, head: "posted in 30 days", num: :posted_30d, prev: :claimed },
      { key: :funnel_30, head: "still there at day 30", num: :retained_30, prev: :posted_30d },
      { key: :funnel_90, head: "still there at day 90", num: :retained_90, prev: :retained_30 }
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
        first_posters: retention&.first_posters.to_i,
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
