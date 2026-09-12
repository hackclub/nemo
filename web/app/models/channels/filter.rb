module Channels
  class Filter
    Field = Struct.new(:key, :label, :kind, :sql, :unit, :omit, keyword_init: true) do
      # a channel cannot have never been created, so that operator has no meaning here
      def ops
        OPS.fetch(kind).except(*Array(omit))
      end
    end

    FIELDS = [
      Field.new(key: "name", label: "Name", kind: :text, sql: "dim_channel.name"),
      Field.new(key: "members", label: "Members", kind: :number, sql: "r.total_members"),
      Field.new(key: "messages", label: "Member messages", kind: :number,
        sql: "r.messages_posted_by_members"),
      Field.new(key: "posters", label: "People who posted", kind: :number,
        sql: "r.members_who_posted"),
      Field.new(key: "readers", label: "People who read", kind: :number,
        sql: "r.members_who_viewed"),
      Field.new(key: "spoke", label: "Share who spoke", kind: :number, unit: "%",
        sql: "(r.members_who_posted::numeric / NULLIF(r.total_members, 0) * 100)"),
      Field.new(key: "read_ratio", label: "Readers per poster", kind: :number, unit: "x",
        sql: "(r.members_who_viewed::numeric / NULLIF(r.members_who_posted, 0))"),
      Field.new(key: "change", label: "Change on the window before", kind: :number, unit: "%",
        sql: "m.pct_change"),
      Field.new(key: "last_post", label: "Last post", kind: :date, sql: "r.last_message_at"),
      Field.new(key: "created", label: "Created", kind: :date,
        sql: "dim_channel.date_created", omit: %w[unset])
    ].freeze

    BY_KEY = FIELDS.index_by(&:key).freeze

    OPS = {
      number: {
        "gt" => ["is over", 1],
        "lt" => ["is under", 1],
        "between" => ["is between", 2],
        "eq" => ["is exactly", 1],
        "set" => ["is known", 0],
        "unset" => ["is not known", 0]
      },
      date: {
        "within" => ["is within the last", 1],
        "before_days" => ["is older than", 1],
        "after" => ["is after", 1],
        "before" => ["is before", 1],
        "unset" => ["never", 0]
      },
      text: {
        "contains" => ["contains", 1],
        "not_contains" => ["does not contain", 1],
        "is" => ["is exactly", 1]
      }
    }.freeze

    MATCHES = %w[all any].freeze
    MAX_CONDITIONS = 12
    DAY_COUNT_OPS = %w[within before_days].freeze

    Condition = Struct.new(:field, :op, :values, keyword_init: true) do
      def label
        arity = OPS.fetch(field.kind).fetch(op).last
        words = OPS.fetch(field.kind).fetch(op).first
        return "#{field.label} #{words}" if arity.zero?

        "#{field.label} #{words} #{values.map { |v| shown(v) }.join(' and ')}"
      end

      def shown(value)
        return "#{value} days" if field.kind == :date && DAY_COUNT_OPS.include?(op)
        return value.to_s if field.kind == :text

        "#{value}#{field.unit}"
      end
    end

    attr_reader :conditions, :match

    # c can arrive keyed by index, c[3][f]=..., or as a plain list, so unwrap both
    def self.from(params, measures: {})
      new(rows: rows_in(params[:c]), match: params[:match], measures: measures)
    end

    def self.rows_in(raw)
      plain = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      list = plain.is_a?(Hash) ? plain.values : Array(plain)
      list.map { |row| row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row }
    end

    def initialize(rows:, match: nil, measures: {})
      @match = MATCHES.include?(match.to_s) ? match.to_s : "all"
      @fields = rebound(measures)
      @conditions = Array(rows).first(MAX_CONDITIONS).filter_map { |row| build(row) }
    end

    def any?
      @conditions.any?
    end

    def size
      @conditions.size
    end

    # returns [sql_with_placeholders, *binds] or nil
    def clause
      return nil if @conditions.empty?

      parts = @conditions.map { |c| piece(c) }
      joiner = @match == "any" ? " OR " : " AND "
      [parts.map(&:first).join(joiner), *parts.flat_map { |p| p.drop(1) }]
    end

    def to_params
      @conditions.each_with_index.to_h do |c, i|
        [i.to_s, { "f" => c.field.key, "op" => c.op, "v" => c.values.map(&:to_s) }]
      end
    end

    private

    # only a known key can be repointed, so the whitelist still decides what is queryable
    def rebound(measures)
      return BY_KEY if measures.blank?

      BY_KEY.transform_values do |field|
        sql = measures[field.key]
        sql ? Field.new(**field.to_h.merge(sql: sql)) : field
      end
    end

    def build(row)
      return nil unless row.is_a?(Hash)

      field = @fields[row["f"].to_s]
      return nil if field.nil?

      ops = field.ops
      op = row["op"].to_s
      return nil unless ops.key?(op)

      wanted = ops.fetch(op).last
      values = Array(row["v"]).reject { |v| v.to_s.strip.empty? }.first(wanted)
      return nil unless values.size == wanted

      cast = values.filter_map { |v| coerce(field, op, v) }
      return nil unless cast.size == wanted

      # a range reads and queries the same way round, so settle the order here
      cast = cast.sort if op == "between"
      Condition.new(field: field, op: op, values: cast)
    end

    def coerce(field, op, raw)
      value = raw.to_s.strip
      case field.kind
      when :number then numeric(value)
      when :date then date_for(op, value)
      when :text then value.presence
      end
    end

    def numeric(value)
      return nil unless value.match?(/\A-?\d+(\.\d+)?\z/)

      value.include?(".") ? value.to_f : value.to_i
    end

    MAX_DAYS = 36_500

    # the operator decides the shape, not the value's own look: within/before_days
    # need a bounded day count, after/before need an actual calendar date, and
    # neither one is a valid stand-in for the other even though both parse cleanly
    def date_for(op, value)
      if DAY_COUNT_OPS.include?(op)
        return nil unless value.match?(/\A\d+\z/)

        days = value.to_i
        days <= MAX_DAYS ? days : nil
      else
        Date.iso8601(value)
      end
    rescue ArgumentError
      nil
    end

    def piece(condition)
      col = condition.field.sql
      one = condition.values.first
      case condition.op
      when "gt" then ["#{col} > ?", one]
      when "lt" then ["#{col} < ?", one]
      when "eq" then ["#{col} = ?", one]
      when "between" then ["#{col} BETWEEN ? AND ?", *condition.values]
      when "set" then ["#{col} IS NOT NULL"]
      when "unset" then unset_for(condition, col)
      when "within" then ["#{col} >= now() - (? || ' days')::interval", one.to_i]
      when "before_days" then ["#{col} < now() - (? || ' days')::interval", one.to_i]
      when "after" then ["#{col} > ?", one]
      when "before" then ["#{col} < ?", one]
      when "contains" then ["#{col} ILIKE ?", "%#{sanitize_like(one)}%"]
      when "not_contains" then ["#{col} NOT ILIKE ?", "%#{sanitize_like(one)}%"]
      when "is" then ["lower(#{col}) = ?", one.to_s.downcase]
      end
    end

    # a channel with no range row has nothing to say, so "never" means it has a
    # row and the column is empty
    def unset_for(condition, col)
      return ["(r.channel_id IS NOT NULL AND #{col} IS NULL)"] if condition.field.sql.start_with?("r.")

      ["#{col} IS NULL"]
    end

    def sanitize_like(value)
      value.to_s.gsub(/[\\%_]/) { |ch| "\\#{ch}" }
    end
  end
end
