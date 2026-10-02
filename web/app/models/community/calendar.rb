module Community
  class Calendar
    WEEKS = 53
    DAYS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze
    SHOWN_DAYS = [0, 2, 4].freeze
    STEPS = 5

    Cell = Struct.new(:on, :messages, :in_channels, :elsewhere, :rooms, :replies,
      :step, :state, keyword_init: true) do
      def measured? = state == :measured
      def before? = state == :before
      def future? = state == :future
      def unseen? = messages.to_i.positive? && rooms.to_i.zero?
    end

    Month = Struct.new(:label, :from, :span, keyword_init: true)

    attr_reader :cells, :months, :window_start, :window_end, :today,
      :peak, :active_days, :thresholds, :run_from, :run_to

    def self.for_member(user_id, zone: Clock::DEFAULT_ZONE, first_post_on: nil,
      run_from: nil, run_to: nil)
      today = Time.current.in_time_zone(Clock.known_zone(zone)).to_date
      window_end = today.end_of_week(:monday)
      window_start = window_end - (WEEKS * 7 - 1)

      held = Analytics::MartMemberDay.mine(user_id).between(window_start, window_end)
        .pluck(:ds, :channels, :replies, :messages)
      posted = Analytics::MemberActivity.mine(user_id).between(window_start, window_end)
        .where("window_start = window_end")
        .pluck(:window_start, :messages_posted, :channel_messages_posted)

      new(held: held, posted: posted, window_start: window_start, window_end: window_end,
        today: today, first_post_on: first_post_on, run_from: run_from, run_to: run_to)
    end

    def initialize(held:, posted:, window_start:, window_end:, today:, first_post_on: nil,
      run_from: nil, run_to: nil)
      @window_start = window_start
      @window_end = window_end
      @today = today
      @first_post_on = first_post_on
      @held = held.to_h { |ds, rooms, replies, messages| [ds, [rooms, replies, messages]] }
      @totals = totals_of(posted)
      counts = @totals.values.map(&:first)
      @peak = counts.max.to_i
      @active_days = counts.count(&:positive?)
      @thresholds = thresholds_for(counts)
      @cells = grid
      @run_from, @run_to = run_of(run_from, run_to)
      @months = month_spans
    end

    def any? = @active_days.positive?

    def weeks = WEEKS

    def column_of(on)
      return nil if on.nil?

      at = on.clamp(@window_start, @window_end)
      ((at - @window_start).to_i / 7) + 1
    end

    RUN_FLOOR = 14

    def run_columns
      return nil if @run_from.nil? || @run_to.nil? || @run_to < @window_start
      return nil if (@run_to - @run_from).to_i + 1 < RUN_FLOOR

      [column_of(@run_from), column_of(@run_to)]
    end

    def row_label(index)
      SHOWN_DAYS.include?(index) ? DAYS[index] : nil
    end

    private

    def thresholds_for(counts)
      live = counts.reject(&:zero?).sort
      under = live.take_while { |count| count < live.last.to_i }
      return [] if under.empty?

      (1...STEPS).map do |i|
        under[((under.length * i) / STEPS.to_f).floor.clamp(0, under.length - 1)]
      end
    end

    def step_of(messages)
      return 0 if messages.to_i.zero?
      return 1 if @thresholds.empty?

      1 + @thresholds.count { |edge| messages > edge }
    end

    def totals_of(posted)
      said = posted.to_h { |ds, messages, in_channels| [ds, [messages.to_i, in_channels.to_i]] }
      (said.keys | @held.keys).to_h do |on|
        archived = @held[on]&.last.to_i
        messages, in_channels = said[on] || [0, 0]
        [on, [[messages, archived].max, [in_channels, archived].max]]
      end
    end

    def grid
      (0...(WEEKS * 7)).map do |offset|
        on = @window_start + offset
        rooms, replies, = @held[on]
        messages, in_channels = @totals[on] || [0, 0]
        Cell.new(on: on, messages: messages, in_channels: in_channels,
          elsewhere: [messages - in_channels, 0].max,
          rooms: rooms.to_i, replies: replies.to_i,
          step: step_of(messages), state: state_of(on))
      end
    end

    def run_of(from, to)
      live = @cells.select { |cell| cell.measured? && cell.messages.positive? }.map(&:on)
      return [from, to] if live.empty?

      last = live.last
      return [from, to] if (@today - last).to_i > 1

      first = last
      first -= 1 while live.include?(first - 1)
      [first, last]
    end

    def state_of(on)
      return :future if on > @today
      return :before if @first_post_on && on < @first_post_on

      :measured
    end

    def month_spans
      seen = []
      (0...WEEKS).each do |week|
        monday = @window_start + (week * 7)
        label = monday.strftime("%b")
        if seen.last && seen.last.label == label
          seen.last.span += 1
        else
          seen << Month.new(label: label, from: week + 1, span: 1)
        end
      end
      seen
    end
  end
end
