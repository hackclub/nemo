module Analytics
  class MartChannelBands < ApplicationRecord
    self.table_name = "analytics.mart_channel_bands"

    scope :in_order, -> { order(:measure_order, :band_order) }

    def self.cohorts
      distinct.order(cohort_month: :desc).pluck(:cohort_month)
    end

    def self.for_cohort(month)
      where(cohort_month: month).in_order
    end

    def self.by_measure
      in_order.to_a.group_by(&:measure_label)
    end

    def readonly?
      true
    end
  end
end
