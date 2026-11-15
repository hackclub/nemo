module Prometheus
  class Appointment < ApplicationRecord
    self.table_name = "app.prometheus_appointment"
    self.primary_key = [:user_id, :channel_id]

    ROLES = %w[manager moderator].freeze

    scope :for_person, ->(user_id) { where(user_id: user_id) }
    scope :in_channel, ->(channel_id) { where(channel_id: channel_id) }
  end
end
