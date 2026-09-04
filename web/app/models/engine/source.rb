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

    def prune_floor_days
      return nil if prune_floor.blank?

      count, unit = prune_floor.split
      count.to_i * (unit.start_with?("month") ? 30 : 1)
    end

    def prunable? = prune_floor.present?

    def limits = @said["limits"] || {}

    def limit(name)
      limits.fetch(name.to_s) { raise Unknown, "#{key} declares no #{name} limit" }
    end

    def guarded? = guard != "none"

    def resumable? = resume != "none"

    def runs_as = @said["runs_as"] || [key]

    STALE_AFTER = { "daily" => 2.days, "weekly" => 8.days, "monthly" => 35.days }.freeze

    def stale_after = STALE_AFTER[cadence]

    def stale?(last_ok)
      return false if stale_after.nil?

      last_ok.nil? || last_ok < stale_after.ago
    end

    def self.feeding(mart)
      @by_mart ||= all.flat_map { |source| source.feeds.map { |fed| [fed, source] } }
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }
      @by_mart[mart.to_s] || []
    end

    def self.for_run(run_source)
      @by_run ||= all.to_h { |source| [source.key, source] }
        .merge(all.flat_map { |source| source.runs_as.map { |name| [name, source] } }.to_h)
      @by_run[run_source] || @by_run[run_source.split(":", 2).first]
    end
  end
end
