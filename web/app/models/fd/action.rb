module Fd
  class Action < ApplicationRecord
    self.table_name = "fd.actions"

    TABLE = YAML.load_file(Rails.root.join("../db/actions.yml")).fetch("actions").freeze
    TYPES = TABLE.keys.freeze
    LABELS = TABLE.transform_values { |row| row.fetch("label") }.freeze
    NEEDS_EXPIRY = TABLE.select { |_key, row| row["expires"] }.keys.freeze
    NEEDS_CHANNEL = TABLE.select { |_key, row| row["channel"] == "required" }.keys.freeze
    TAKES_CHANNEL = TABLE.select { |_key, row| row["channel"].present? }.keys.freeze

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :actions
    belongs_to :cited_message, class_name: "Fd::ThreadMessage",
      foreign_key: :cites_message_id, optional: true

    scope :live, -> { where(reversed_at: nil) }
    scope :reversed, -> { where.not(reversed_at: nil) }
    scope :recent_first, -> { order(performed_at: :desc) }
    scope :oldest_first, -> { order(:performed_at) }
    scope :for_target, ->(user_id) { where(target_user_id: user_id) }
    scope :expiring, -> { live.where.not(expires_at: nil) }

    def reversed?
      reversed_at.present?
    end

    def cites?
      cites_message_id.present?
    end

    def expires?
      expires_at.present?
    end

    def expired?(at = Time.current)
      expires? && !reversed? && expires_at <= at
    end

    def active?(at = Time.current)
      !reversed? && !expired?(at)
    end

    def performed_by_decider?
      decided_by == performed_by
    end
  end
end
