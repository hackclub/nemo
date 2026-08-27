module Engine
  class Freshness
    SWITCH = "stale_reads_as_stale".freeze

    def self.on?
      Setting.value(Setting::ENGINE, SWITCH) != "false"
    end

    def self.last_success
      Current.fresh ||= Analytics::FctIngestRun
        .where(status: "ok")
        .where.not(finished_at: nil)
        .pluck(:source, :finished_at)
        .filter_map { |source, at| [Source.for_run(source)&.key, at] }
        .reject { |key, _at| key.nil? }
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last).max }
    end

    def self.stale(mart)
      return nil unless on?

      Source.feeding(mart).filter_map { |source|
        at = last_success[source.key]
        next nil unless source.stale?(at)

        [source.key, at]
      }.first
    end

    def self.note(mart)
      key, at = stale(mart)
      return nil if key.nil?
      return "#{key} has never run" if at.nil?

      "#{key} last ran #{ActionController::Base.helpers.time_ago_in_words(at)} ago"
    end
  end
end
