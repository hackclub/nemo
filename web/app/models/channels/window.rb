module Channels
  class Window
    PRESETS = [7, 30, 90].freeze

    PULLED_SQL = "#{Joins::RANGE}.messages_posted_by_members".freeze
    ROLLED_SQL = "#{Joins::ROLLUP}.range_messages".freeze

    attr_reader :days, :start_date, :end_date, :pulled_start, :pulled_end, :edge

    def self.from(params)
      lo, hi = pulled_bounds
      new(days: params[:days], pulled_start: lo, pulled_end: hi,
          edge: Analytics::MartChannelActivity.maximum(:window_start))
    end

    def self.pulled_bounds
      row = Analytics::MartChannelRange
        .select("min(window_start) AS lo, max(window_end) AS hi").take
      [row&.lo, row&.hi]
    end

    def initialize(days:, pulled_start:, pulled_end:, edge:)
      @pulled_start = pulled_start
      @pulled_end = pulled_end
      @edge = edge
      @days = settle(days)
      @end_date = pulled? ? @pulled_end : @edge
      @start_date = pulled? ? @pulled_start : (@edge && @edge - (@days - 1))
    end

    def pulled_days
      return nil if @pulled_start.nil? || @pulled_end.nil?

      (@pulled_end - @pulled_start).to_i + 1
    end

    def choices
      ([pulled_days] + PRESETS).compact.uniq.sort
    end

    def pulled?
      @edge.nil? || @days == pulled_days
    end

    def adjustable?
      @edge.present? && choices.many?
    end

    def join
      return nil if pulled?

      ActiveRecord::Base.sanitize_sql_array(
        ["LEFT JOIN (SELECT channel_id, sum(messages_posted_by_members) AS range_messages " \
         "FROM analytics.mart_channel_activity " \
         "WHERE window_start BETWEEN ? AND ? GROUP BY channel_id) #{Joins::ROLLUP} " \
         "ON #{Joins::ROLLUP}.channel_id = #{Joins::SPINE}.channel_id", @start_date, @end_date]
      )
    end

    def measure_sql
      pulled? ? PULLED_SQL : ROLLED_SQL
    end

    def column
      pulled? ? "#{PULLED_SQL} AS range_messages" : ROLLED_SQL
    end

    def measures
      pulled? ? {} : { "messages" => ROLLED_SQL }
    end

    def asked
      @days unless pulled?
    end

    private

    def settle(asked)
      wanted = asked.to_i
      return wanted if choices.include?(wanted)

      pulled_days || PRESETS.min
    end
  end
end
