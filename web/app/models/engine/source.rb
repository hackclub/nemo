module Engine
  class Source
    class Unknown < ArgumentError; end

    FILE = YAML.load_file(Rails.root.join("../db/sources.yml")).freeze
    TABLE = FILE.fetch("sources").freeze
    KEYS = TABLE.keys.freeze
    CADENCES = FILE.fetch("cadences").freeze
    GUARDS = FILE.fetch("guards").freeze
    RESUMES = FILE.fetch("resumes").freeze
    RETENTIONS = FILE.fetch("retentions").freeze

    DECLARED = %w[cadence window guard resume retention writes feeds].freeze

    attr_reader :key

    def initialize(key)
      @key = key.to_s
      @said = TABLE.fetch(@key) { raise Unknown, "#{key} is not a source" }
    end

    def self.all
      KEYS.map { |key| new(key) }
    end

    def self.[](key)
      new(key)
    end

    DECLARED.each do |field|
      define_method(field) { @said.fetch(field) }
    end

    def label = @said.fetch("label")

    def endpoint = @said.fetch("endpoint")

    def credential = @said.fetch("credential")

    def prune_floor = @said["prune_floor"]

    def limits = @said["limits"] || {}

    def limit(name)
      limits.fetch(name.to_s) { raise Unknown, "#{key} declares no #{name} limit" }
    end

    def guarded? = guard != "none"

    def resumable? = resume != "none"
  end
end
