module Community
  class Clock
    DAYS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze
    HOURS = (0..23).to_a.freeze

    RAMP = %w[
      #30123b #4454c4 #4490fe #1fc8de #29efa2
      #7dff56 #c1f334 #f1ca3a #fe922a #ea4f0d #7a0403
    ].freeze

    EMPTY = "transparent".freeze

    Cell = Struct.new(:day, :hour, :messages, :share, :tone, keyword_init: true)

    attr_reader :rows, :peak, :total, :window_start, :window_end

    def self.workspace_wide
      rows = Analytics::MartActivityClock.order(:day_of_week, :hour_of_day).to_a
      head = rows.first
      new(rows: rows, window_start: head&.window_start, window_end: head&.window_end)
    end

    def self.for_channel(channel_id)
      rows = Analytics::MartChannelClock
        .where(channel_id: channel_id).order(:day_of_week, :hour_of_day).to_a
      head = rows.first
      new(rows: rows, window_start: head&.window_start, window_end: head&.window_end)
    end

    def initialize(rows:, window_start:, window_end:)
      @window_start = window_start
      @window_end = window_end
      @counts = rows.to_h { |r| [[r.day_of_week, r.hour_of_day], r.messages.to_i] }
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
        tone: tone(messages, share))
    end

    def tone(messages, share)
      return EMPTY if messages.zero?

      RAMP[(share * (RAMP.size - 1)).round]
    end
  end
end
