module Analytics
  class MartCohortSurvival < ApplicationRecord
    self.table_name = "analytics.mart_cohort_survival"

    Curve = Struct.new(:cohort_month, :members, :shares, keyword_init: true) do
      def drawn_to = shares.rindex { |share| !share.nil? }

      def at(offset) = shares[offset]

      def partial?(ladder) = drawn_to.to_i < ladder.length - 1
    end

    def readonly?
      true
    end

    def self.offsets
      return [] unless table_exists?

      (0..maximum(:horizon_days).to_i).to_a
    end

    def self.curves(cohorts:, floor:)
      return [] unless table_exists?

      months = distinct.where(members: floor..).order(cohort_month: :desc)
        .limit(cohorts).pluck(:cohort_month).sort
      return [] if months.empty?

      ladder = offsets
      held = where(cohort_month: months, observable: true)
        .pluck(:cohort_month, :day_offset, :still_posting_share, :members)
        .group_by(&:first)
      months.filter_map do |month|
        seen = held[month] || []
        next if seen.length < 2

        share = seen.to_h { |_, offset, value, _| [offset, value&.to_f] }
        Curve.new(cohort_month: month, members: seen.first.fourth.to_i,
          shares: ladder.map { |offset| share[offset] })
      end
    end
  end
end
