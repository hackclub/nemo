module Fd
  class Flag < ApplicationRecord
    self.table_name = "fd.app_flags"

    class Unknown < ArgumentError; end

    TABLE = YAML.load_file(Rails.root.join("../db/flags.yml")).fetch("flags").freeze
    KEYS = TABLE.keys.freeze

    def self.fetch(key)
      TABLE.fetch(key.to_s) { raise Unknown, "#{key} is not a flag" }
    end

    def self.label(key) = fetch(key).fetch("label")

    def self.covers(key) = fetch(key).fetch("covers")

    def self.default?(key) = fetch(key).fetch("default") == true

    def self.flipped
      pluck(:key, :is_on).to_h
    end

    def self.on?(key)
      fetch(key)
      Current.flags.fetch(key.to_s) { default?(key) }
    end

    def self.off?(key) = !on?(key)

    def self.set!(key, on, by:)
      fetch(key)
      row = find_or_initialize_by(key: key.to_s)
      row.update!(is_on: on, changed_by: by, changed_at: Time.current)
      Current.forget_flags
      row
    end

    def self.showing
      KEYS.select { |key| on?(key) }
    end
  end
end
