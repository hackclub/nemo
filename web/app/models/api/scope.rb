module Api
  class Scope
    class UnknownError < ArgumentError; end

    TABLE = YAML.load_file(Rails.root.join("../db/api_scopes.yml"))
      .fetch("scopes").freeze
    KEYS = TABLE.keys.freeze

    def self.fetch(key)
      TABLE.fetch(key.to_s) { raise UnknownError, "#{key} is not a scope" }
    end

    def self.label(key) = fetch(key).fetch("label")

    def self.covers(key) = fetch(key).fetch("covers")

    def self.known?(key) = TABLE.key?(key.to_s)

    def self.label_for(key) = known?(key) ? label(key).downcase : key.to_s
  end
end
