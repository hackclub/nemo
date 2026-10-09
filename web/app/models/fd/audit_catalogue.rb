module Fd
  module AuditCatalogue
    HELD = YAML.load_file(Rails.root.join("../db/audit_actions.yml")).freeze
    CATEGORIES = HELD.fetch("categories").freeze
    ACTIONS = HELD.fetch("actions").freeze

    def self.category_label(key) = CATEGORIES.fetch(key.to_s, key.to_s.tr("_", " "))

    def self.category_for(value)
      asked = value.to_s.strip.downcase
      CATEGORIES.find { |key, label| key == asked || label.downcase == asked }&.first
    end

    def self.action_label(action) = ACTIONS.dig(action.to_s, "label") || action.to_s.tr("_", " ")

    def self.actions_in(categories)
      ACTIONS.select { |_action, one| categories.include?(one["category"]) }.keys
    end

    def self.grouped(categories = CATEGORIES.keys)
      categories.map do |key|
        actions = ACTIONS.select { |_action, one| one["category"] == key }
          .sort_by { |_action, one| one["label"].to_s }.map(&:first)
        [key, category_label(key), actions]
      end
    end
  end
end
