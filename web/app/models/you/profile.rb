module You
  class Profile
    SPANS = {
      "30d" => { label: "30 days", days: 30 },
      "90d" => { label: "90 days", days: 90 },
      "all" => { label: "all time", days: nil }
    }.freeze
    DEFAULT_SPAN = "all".freeze
    TOP_CHANNELS = 6

    STREAK_BASES = {
      "posted" => "days you posted",
      "online" => "days you were online"
    }.freeze
    DEFAULT_BASIS = "posted".freeze

    SLACK = {
      days_active: "days_active",
      days_ios: "days_active_ios",
      days_desktop: "days_active_desktop",
      days_android: "days_active_android",
      messages: "messages_posted",
      channel_messages: "channel_messages_posted",
      reactions_given: "reactions_added",
      huddles: "huddles",
      files: "files_uploaded",
      searches: "searches"
    }.freeze

    ARCHIVE = {
      messages: "sum(messages)",
      replies: "sum(replies)",
      threads_started: "sum(threads_started)",
      reactions_received: "sum(reactions_received)",
      days_posted: "count(*) filter (where messages > 0)",
      busiest_day: "max(messages)"
    }.freeze

    def self.span_key(asked)
      SPANS.key?(asked.to_s) ? asked.to_s : DEFAULT_SPAN
    end

    def self.basis(asked)
      STREAK_BASES.key?(asked.to_s) ? asked.to_s : DEFAULT_BASIS
    end

    def self.on(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    attr_reader :user_id, :span_key, :zone, :streak_basis

    def initialize(user_id, span: DEFAULT_SPAN, start_on: nil, end_on: nil, streak: DEFAULT_BASIS,
      zone: Community::Clock::DEFAULT_ZONE)
      @user_id = user_id
      @span_key = self.class.span_key(span)
      @streak_basis = self.class.basis(streak)
      @zone = Community::Clock.known_zone(zone)
      @asked_start = self.class.on(start_on)
      @asked_end = self.class.on(end_on)
    end

    def span = SPANS.fetch(@span_key)

    def today
      @today ||= Time.current.in_time_zone(@zone).to_date
    end

    def floor
      return @floor if defined?(@floor)

      @floor = first_measured_on
    end

    def ceiling = today

    def custom?
      return @custom unless @custom.nil?

      @custom = (@asked_start || @asked_end).present? && floor.present?
    end

    def window
      @window ||= custom? ? asked_window : preset_window
    end

    def window_start = window.first

    def window_end = window.last

    def window_days = (window_end - window_start).to_i + 1

    def prior_window
      return nil if !custom? && span[:days].nil?

      [window_start - window_days, window_start - 1]
    end

    def here_since
      return @here_since if defined?(@here_since)

      @here_since = Analytics::DimMemberCohort.find_by(user_id: @user_id)&.cohort_at
    end

    def first_post_on
      return @first_post_on if defined?(@first_post_on)

      @first_post_on = Analytics::MartMemberDay.mine(@user_id).minimum(:ds)
    end

    def streak
      return @streak if defined?(@streak)

      @streak = Analytics::MartMemberStreak.mine(@user_id).counting(@streak_basis).take
    end

    def slack(from = window_start, to = window_end)
      @slack ||= {}
      @slack[[from, to]] ||= read(
        Analytics::MemberActivity.mine(@user_id).between(from, to),
        SLACK.transform_values { |column| "sum(#{column})" }
      )
    end

    def held(from = window_start, to = window_end)
      @held ||= {}
      @held[[from, to]] ||= read(
        Analytics::MartMemberDay.mine(@user_id).between(from, to), ARCHIVE
      )
    end

    def prior_slack
      return nil if prior_window.nil?

      @prior_slack ||= slack(*prior_window)
    end

    def days_reacted
      @days_reacted ||= Analytics::MemberActivity.mine(@user_id)
        .between(window_start, window_end)
        .where("coalesce(reactions_added, 0) > 0").count
    end

    def messages_elsewhere
      slack[:messages].to_i - slack[:channel_messages].to_i
    end

    def platform_share(key)
      return nil if slack[:days_active].to_i.zero? || slack[key].nil?

      (slack[key].to_f / slack[:days_active] * 100).round
    end

    def platforms_known?
      %i[days_ios days_desktop days_android].any? { |key| slack[key].to_i.positive? }
    end

    def channels
      @channels ||= begin
        rows = Analytics::MemberChannel.mine(@user_id)
          .order(messages: :desc, channel_id: :asc).limit(TOP_CHANNELS).to_a
        names = Analytics::DimChannel.where(channel_id: rows.map(&:channel_id))
          .pluck(:channel_id, :name).to_h
        rows.map { |row| [row, names[row.channel_id]] }
      end
    end

    def channels_posted_in
      @channels_posted_in ||= Analytics::MemberChannel.mine(@user_id).count
    end

    def channel_messages_all_time
      @channel_messages_all_time ||= Analytics::MemberChannel.mine(@user_id).sum(:messages)
    end

    def calendar
      @calendar ||= Community::Calendar.for_member(@user_id, zone: @zone,
        first_post_on: first_post_on, run_from: streak&.current_from,
        run_to: streak&.current_to)
    end

    def clock
      @clock ||= Community::Clock.for_member(@user_id, zone: @zone)
    end

    def weeks
      @weeks ||= begin
        posted = Analytics::MemberActivity.mine(@user_id).between(window_start, window_end)
          .where("window_start = window_end")
          .group(Arel.sql("date_trunc('week', window_start)::date")).sum(:messages_posted)
        reacted = Analytics::MemberActivity.mine(@user_id).between(window_start, window_end)
          .group(Arel.sql("date_trunc('week', window_start)::date")).sum(:reactions_added)

        mondays.map do |monday|
          { on: monday, messages: posted[monday].to_i, reactions: reacted[monday].to_i }
        end
      end
    end

    def busiest_week
      @busiest_week ||= weeks.max_by { |week| week[:messages] }
    end

    def any?
      held[:messages].to_i.positive? || slack[:days_active].to_i.positive?
    end

    def measured_through
      @measured_through ||= streak&.measured_through ||
        Analytics::MemberActivity.mine(@user_id).maximum(:window_start)
    end

    private

    def asked_window
      to = (@asked_end || ceiling).clamp(floor, ceiling)
      from = (@asked_start || to).clamp(floor, to)
      [from, to]
    end

    def preset_window
      days = span[:days]
      from = days ? today - (days - 1) : (floor || today)
      [from, today]
    end

    def mondays
      first = window_start.beginning_of_week(:monday)
      last = window_end.beginning_of_week(:monday)
      (first..last).step(7).to_a
    end

    def first_measured_on
      [first_post_on, Analytics::MemberActivity.mine(@user_id).minimum(:window_start)]
        .compact.min
    end

    def read(scope, columns)
      picked = columns.values.map { |sql| Arel.sql(sql) }
      values = Array(scope.pluck(*picked).first)
      columns.keys.each_with_index.to_h { |key, i| [key, values[i]&.to_i] }
    end
  end
end
