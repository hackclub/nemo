module Api
  class Capability
    class Unknown < ArgumentError; end

    TABLE = YAML.load_file(Rails.root.join("../db/capabilities.yml"))
      .fetch("capabilities").freeze
    KEYS = TABLE.keys.freeze

    def self.fetch(key)
      TABLE.fetch(key.to_s) { raise Unknown, "#{key} is not a capability" }
    end

    def self.label(key) = fetch(key).fetch("label")

    def self.covers(key) = fetch(key).fetch("covers")

    def self.known?(key) = TABLE.key?(key.to_s)

    def self.said(key) = known?(key) ? label(key).downcase : key.to_s
  end
end
