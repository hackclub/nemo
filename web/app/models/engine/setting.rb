module Engine
  class Setting < ApplicationRecord
    self.table_name = "engine_setting"

    class Refused < ArgumentError; end

    ENGINE = "engine".freeze
    CADENCE = "cadence".freeze
    ENABLED = "enabled".freeze
    RETENTION = "retention_days".freeze
    KEEP = "keep".freeze
    LONGEST = 3650

    ENGINE_DIALS = {
      "run_at" => { label: "Nightly at", default: "03:00", kind: :time },
      "budget_minutes" => { label: "Budget for one night", default: "45", kind: :number,
                            min: 5, max: 480 },
      Engine::Freshness::SWITCH => { label: "Stale cards read n/a", default: "true", kind: :switch }
    }.freeze

    def self.overrides
      Current.tuned ||= pluck(:source, :name, :value)
        .to_h { |source, name, value| [[source, name], value] }
    end

    def self.raw(source, name)
      overrides[[source.to_s, name.to_s]]
    end

    def self.value(source, name)
      raw(source, name) || default(source, name)
    end

    def self.default(source, name)
      return ENGINE_DIALS.fetch(name.to_s).fetch(:default) if source.to_s == ENGINE
      return Source[source].cadence if name.to_s == CADENCE
      return "true" if name.to_s == ENABLED
      return KEEP if name.to_s == RETENTION

      Source[source].limit(name).fetch("default").to_s
    end

    def self.changed?(source, name)
      raw(source, name).present?
    end

    def self.on?(source)
      value(source, ENABLED).to_s != "false"
    end

    def self.cadence(source)
      value(source, CADENCE)
    end

    def self.number(source, name)
      value(source, name).to_i
    end

    def self.set!(source, name, value, by:)
      value = checked(source.to_s, name.to_s, value.to_s.strip)
      row = find_or_initialize_by(source: source.to_s, name: name.to_s)
      row.update!(value: value, changed_by: by, changed_at: Time.current)
      Current.forget_tuned
      row
    end

    def self.reset!(source, name, by:)
      row = find_by(source: source.to_s, name: name.to_s)
      return nil if row.nil?

      row.destroy!
      Current.forget_tuned
      row
    end

    def self.checked(source, name, value)
      raise Refused, "#{name} cannot be blank" if value.blank?

      if source == ENGINE
        return checked_engine(name, value)
      end

      case name
      when CADENCE
        return value if Source::CADENCES.include?(value)

        raise Refused, "#{value} is not a cadence"
      when ENABLED
        return value if %w[true false].include?(value)

        raise Refused, "#{value} is not true or false"
      when RETENTION
        checked_retention(source, value)
      else
        in_bounds(Source[source].limit(name), name, value)
      end
    end

    def self.checked_retention(source, value)
      return KEEP if value.casecmp(KEEP).zero?

      floor = Source[source].prune_floor_days
      raise Refused, "#{source} does not delete anything" if floor.nil?

      in_bounds({ "min" => floor, "max" => LONGEST }, RETENTION, value)
    end

    def self.checked_engine(name, value)
      dial = ENGINE_DIALS.fetch(name) { raise Refused, "#{name} is not an engine setting" }
      if dial[:kind] == :switch
        return value if %w[true false].include?(value)

        raise Refused, "#{value} is not true or false"
      end
      return value if dial[:kind] == :time && value.match?(/\A([01]\d|2[0-3]):[0-5]\d\z/)
      raise Refused, "#{value} is not a time of day" if dial[:kind] == :time

      in_bounds(dial.transform_keys(&:to_s), name, value)
    end

    def self.in_bounds(bounds, name, value)
      raise Refused, "#{name} has to be a number" unless value.match?(/\A\d+\z/)

      asked = value.to_i
      low = bounds.fetch("min")
      high = bounds.fetch("max")
      return value if asked.between?(low, high)

      raise Refused, "#{name} has to be between #{low} and #{high}"
    end
  end
end
