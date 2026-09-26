module Community
  class Clock
    DAYS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze
    HOURS = (0..23).to_a.freeze
    WINDOW_DAYS = 91
    DEFAULT_ZONE = "UTC".freeze

    RAMP = [
      "var(--clk-0)", "var(--clk-1)", "var(--clk-2)",
      "var(--clk-3)", "var(--clk-4)", "var(--clk-5)"
    ].freeze

    FOLD = <<~SQL.freeze
      select
          extract(isodow from at_local)::integer as day_of_week,
          extract(hour from at_local)::integer as hour_of_day,
          sum(messages)::bigint as messages,
          window_start,
          window_end
      from local_at
      where at_local::date between window_start and window_end
      group by 1, 2, 4, 5
      order by 1, 2
    SQL

    WORKSPACE = (<<~SQL + FOLD).freeze
      with edge as (
          select max(ds) as last_day
          from analytics.mart_workspace_hour
      ),

      span as (
          select (last_day - ?)::date as window_start, last_day as window_end
          from edge
      ),

      local_at as (
          select
              ((w.ds + w.hour_of_day * interval '1 hour') at time zone 'UTC')
                  at time zone ? as at_local,
              w.messages,
              s.window_start,
              s.window_end
          from analytics.mart_workspace_hour w
          cross join span s
          where w.ds between s.window_start - 1 and s.window_end + 1
      )

    SQL

    CHANNEL = (<<~SQL + FOLD).freeze
      with edge as (
          select max(ds) as last_day
          from analytics.fct_message_hour
      ),

      span as (
          select (last_day - ?)::date as window_start, last_day as window_end
          from edge
      ),

      walked as (
          select channel_id
          from analytics.fct_channel_walk
          where coalesce(history_complete, false)
      ),

      local_at as (
          select
              ((h.ds + h.hour_of_day * interval '1 hour') at time zone 'UTC')
                  at time zone ? as at_local,
              h.member_messages as messages,
              s.window_start,
              s.window_end
          from analytics.fct_message_hour h
          cross join span s
          inner join walked c on c.channel_id = h.channel_id
          where h.ds between s.window_start - 1 and s.window_end + 1
            and h.channel_id = ?
      )

    SQL

    MEMBER = (<<~SQL + FOLD).freeze
      with edge as (
          select max(ds) as last_day
          from analytics.mart_member_hour
      ),

      span as (
          select (last_day - ?)::date as window_start, last_day as window_end
          from edge
      ),

      local_at as (
          select
              ((h.ds + h.hour_of_day * interval '1 hour') at time zone 'UTC')
                  at time zone ? as at_local,
              h.messages,
              s.window_start,
              s.window_end
          from analytics.mart_member_hour h
          cross join span s
          where h.ds between s.window_start - 1 and s.window_end + 1
            and h.user_id = ?
      )

    SQL

    Cell = Struct.new(:day, :hour, :messages, :share, :tone, keyword_init: true)

    attr_reader :rows, :peak, :total, :window_start, :window_end, :zone

    def self.zones
      @zones ||= Set.new(TZInfo::Timezone.all_identifiers)
    end

    def self.known_zone(value)
      name = value.to_s.strip
      zones.include?(name) ? name : DEFAULT_ZONE
    end

    def self.workspace_wide(zone: DEFAULT_ZONE)
      build(zone, nil)
    end

    def self.for_channel(channel_id, zone: DEFAULT_ZONE)
      build(zone, channel_id)
    end

    def self.for_member(user_id, zone: DEFAULT_ZONE)
      build(zone, nil, member_id: user_id)
    end

    def self.build(zone, channel_id, member_id: nil)
      zone = known_zone(zone)
      sql = ApplicationRecord.sanitize_sql_array(
        if member_id
          [MEMBER, WINDOW_DAYS - 1, zone, member_id]
        elsif channel_id
          [CHANNEL, WINDOW_DAYS - 1, zone, channel_id]
        else
          [WORKSPACE, WINDOW_DAYS - 1, zone]
        end
      )
      rows = ApplicationRecord.connection.select_all(sql, "Community::Clock").to_a
      head = rows.first
      new(rows: rows, zone: zone,
        window_start: head && head["window_start"],
        window_end: head && head["window_end"])
    end

    def initialize(rows:, zone:, window_start:, window_end:)
      @zone = zone
      @window_start = window_start
      @window_end = window_end
      @counts = rows.to_h { |r| [[r["day_of_week"], r["hour_of_day"]], r["messages"].to_i] }
      @total = @counts.values.sum
      @peak = @counts.values.max.to_i
      @rows = grid
    end

    def any?
      @peak.positive?
    end

    def busiest
      @rows.flat_map(&:last).max_by(&:messages)
    end

    def label
      Time.current.in_time_zone(@zone).strftime("%Z")
    rescue ArgumentError
      @zone
    end

    private

    def grid
      DAYS.each_with_index.map do |name, i|
        [name, HOURS.map { |hour| cell(i + 1, hour) }]
      end
    end

    def cell(dow, hour)
      messages = @counts.fetch([dow, hour], 0)
      share = @peak.positive? ? messages.to_f / @peak : 0.0
      Cell.new(day: DAYS[dow - 1], hour: hour, messages: messages, share: share,
        tone: tone(messages))
    end

    def tone(messages)
      return RAMP.first if messages.zero?

      step = cuts.count { |cut| messages > cut }
      RAMP[step + 1]
    end

    def cuts
      @cuts ||= begin
        spoken = @counts.values.reject(&:zero?).sort
        steps = RAMP.size - 2
        if spoken.size < steps
          []
        else
          (1...steps).map { |i| spoken[(spoken.size * i) / steps] }
        end
      end
    end
  end
end
