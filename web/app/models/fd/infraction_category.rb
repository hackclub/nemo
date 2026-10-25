module Fd
  class InfractionCategory < ApplicationRecord
    self.table_name = "fd.infraction_categories"
    self.primary_key = "key"

    LABEL_LENGTH = 80
    NO_REASON_KEYS = %w[adult].freeze

    scope :ordered, -> { order(:position, :key) }
    scope :active, -> { where(retired_at: nil) }

    validates :label, presence: true, length: { maximum: LABEL_LENGTH }

    def self.key_for(label)
      base = label.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      base = "category_#{base}" unless base.match?(/\A[a-z]/)
      key = base
      key = "#{base}_#{(2..).find { |n| !exists?(key: "#{base}_#{n}") }}" if exists?(key: base)
      key
    end

    def self.next_position = (maximum(:position) || 0) + 1

    def self.all_ordered = Current.categories ||= ordered.to_a

    def self.labels = all_ordered.to_h { |category| [category.key, category.label] }

    def self.active_keys = all_ordered.reject(&:retired?).map(&:key)

    def self.label(key) = labels.fetch(key.to_s) { key.to_s.tr("_", " ") }

    def self.active_key?(key) = active_keys.include?(key.to_s)

    def self.known_key?(key) = labels.key?(key.to_s)

    def self.needs_reason?(key) = NO_REASON_KEYS.exclude?(key.to_s)

    def retired? = retired_at.present?
  end
end
