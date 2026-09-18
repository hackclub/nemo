module Community
  class Calendar
    WEEKS = 53
    DAYS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze
    SHOWN_DAYS = [0, 2, 4].freeze
    STEPS = 5

    Cell = Struct.new(:on, :messages, :channels, :replies, :step, :state, keyword_init: true) do
      def measured? = state == :measured
      def before? = state == :before
      def future? = state == :future
    end

    Month = Struct.new(:label, :from, :span, keyword_init: true)

    attr_reader :cells, :months, :window_start, :window_end, :today,
      :peak, :active_days, :thresholds, :run_from, :run_to

    def self.for_member(user_id, zone: Clock::DEFAULT_ZONE, first_post_on: nil,
      run_from: nil, run_to: nil)
      today = Time.current.in_time_zone(Clock.known_zone(zone)).to_date
      window_end = today.end_of_week(:monday)
      window_start = window_end - (WEEKS * 7 - 1)

      rows = Analytics::MartMemberDay.mine(user_id).between(window_start, window_end)
        .pluck(:ds, :messages, :channels, :replies)

      new(rows: rows, window_start: window_start, window_end: window_end, today: today,
        first_post_on: first_post_on, run_from: run_from, run_to: run_to)
    end

    def initialize(rows:, window_start:, window_end:, today:, first_post_on: nil,
      run_from: nil, run_to: nil)
      @window_start = window_start
      @window_end = window_end
      @today = today
      @first_post_on = first_post_on
      @run_from = run_from
      @run_to = run_to
      @held = rows.to_h { |ds, messages, channels, replies| [ds, [messages, channels, replies]] }
      @peak = rows.map { |r| r[1].to_i }.max.to_i
      @active_days = rows.count { |r| r[1].to_i.positive? }
      @thresholds = thresholds_for(rows.map { |r| r[1].to_i })
      @cells = grid
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
      return [] if live.empty?

      (1...STEPS).map do |i|
        live[((live.length * i) / STEPS.to_f).floor.clamp(0, live.length - 1)]
      end
    end

    def step_of(messages)
      return 0 if messages.to_i.zero?
      return 1 if @thresholds.empty?

      1 + @thresholds.count { |edge| messages > edge }
    end

    def grid
      (0...(WEEKS * 7)).map do |offset|
        on = @window_start + offset
        held = @held[on]
        Cell.new(on: on, messages: held&.first.to_i, channels: held&.[](1).to_i,
          replies: held&.[](2).to_i, step: step_of(held&.first), state: state_of(on))
      end
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
