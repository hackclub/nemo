module Prometheus
  class Appointment < ApplicationRecord
    self.table_name = "app.prometheus_appointment"
    self.primary_key = [:user_id, :channel_id]

    MANAGER = "manager".freeze
    ROLES = %w[manager moderator].freeze

    scope :managing, -> { where(role: MANAGER) }
    scope :for_person, ->(user_id) { where(user_id: user_id) }
    scope :in_channel, ->(channel_id) { where(channel_id: channel_id) }
  end
end
