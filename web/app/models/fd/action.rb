module Fd
  class Action < ApplicationRecord
    self.table_name = "fd.actions"

    TABLE = YAML.load_file(Rails.root.join("../db/actions.yml")).fetch("actions").freeze
    TYPES = TABLE.keys.freeze
    LABELS = TABLE.transform_values { |row| row.fetch("label") }.freeze
    NEEDS_EXPIRY = TABLE.select { |_key, row| row["expires"] }.keys.freeze
    NEEDS_CHANNEL = TABLE.select { |_key, row| row["channel"] == "required" }.keys.freeze
    TAKES_CHANNEL = TABLE.select { |_key, row| row["channel"].present? }.keys.freeze
    WORST_FIRST = TABLE.sort_by { |_key, row| row.fetch("weight") }.map(&:first).freeze
    FROM_THREAD_LOCK = TABLE.select { |_key, row| row["thread_lock"] }.keys.freeze
    ENFORCE = TABLE.transform_values { |row| row["enforce"] }.compact.freeze
    ENFORCEABLE = ENFORCE.keys.freeze

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :actions
    belongs_to :guard, class_name: "Fd::MemberGuard", foreign_key: :guard_id,
      optional: true, inverse_of: :actions
    belongs_to :thread_guard, class_name: "Fd::ThreadGuard", foreign_key: :thread_guard_id,
      optional: true, inverse_of: :actions

    scope :live, -> { where(reversed_at: nil) }
    scope :reversed, -> { where.not(reversed_at: nil) }
    scope :recent_first, -> { order(performed_at: :desc) }
    scope :oldest_first, -> { order(:performed_at) }
    scope :for_target, ->(user_id) { where(target_user_id: user_id) }
    scope :expiring, -> { live.where.not(expires_at: nil) }
    scope :in_force, ->(at = Time.current) { live.where("expires_at > ?", at) }

    def self.guard_kind(type_key) = ENFORCE.dig(type_key, "guard")

    def self.guard_scope(type_key) = ENFORCE.dig(type_key, "scope")

    def self.enforceable?(type_key) = ENFORCE.key?(type_key)

    def self.from_thread_lock?(type_key) = FROM_THREAD_LOCK.include?(type_key)

    def self.guards_logged_on(case_ids)
      live.where(case_id: case_ids).where.not(guard_id: nil).pluck(:guard_id).to_set
    end

    def self.thread_guards_logged_on(case_ids)
      live.where(case_id: case_ids).where.not(thread_guard_id: nil)
        .pluck(:thread_guard_id).to_set
    end

    def reversed?
      reversed_at.present?
    end

    def enforceable? = self.class.enforceable?(type_key)

    def from_thread_lock? = self.class.from_thread_lock?(type_key)

    def aimed_at_member? = target_user_id.present?

    def expires?
      expires_at.present?
    end

    def expired?(at = Time.current)
      expires? && !reversed? && expires_at <= at
    end

    def active?(at = Time.current)
      !reversed? && !expired?(at)
    end

    def in_force?(at = Time.current)
      expires? && !reversed? && expires_at > at
    end

    def performed_by_decider?
      decided_by == performed_by
    end
  end
end
