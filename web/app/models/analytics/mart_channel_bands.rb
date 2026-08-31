module Analytics
  class MartChannelBands < ApplicationRecord
    self.table_name = "analytics.mart_channel_bands"

    scope :in_order, -> { order(:measure_order, :band_order) }

    def self.by_measure
      in_order.to_a.group_by(&:measure_label)
    end

    def readonly?
      true
    end
  end
end
