require "test_helper"

class Community::CalendarTest < ActiveSupport::TestCase
  def build(rows, today: Date.new(2026, 9, 18), held: nil, **rest)
    window_end = today.end_of_week(:monday)
    posted = rows.map { |on, messages, _rooms, _replies| [on, messages, messages] }
    Community::Calendar.new(
      held: held || rows.map { |on, messages, rooms, replies| [on, rooms, replies, messages] },
      posted: posted, window_start: window_end - (53 * 7 - 1),
      window_end: window_end, today: today, **rest)
  end

  test "the grid is always a full 53 weeks of days" do
    cal = build([])

    assert_equal 53 * 7, cal.cells.size
    assert_equal cal.window_start, cal.cells.first.on
    assert_not cal.any?
  end

  test "the ramp steps on the member's own days, not the workspace's" do
    quiet = build((1..40).map { |n| [Date.new(2026, 9, 1) - n, (n % 4) + 1, 1, 0] })
    loud = build((1..40).map { |n| [Date.new(2026, 9, 1) - n, n * 25, 9, 4] })

    assert_equal 5, quiet.cells.map(&:step).max, "a quiet member still reaches the top step"
    assert_equal 5, loud.cells.map(&:step).max
    assert_operator loud.peak, :>, quiet.peak
  end

  test "a day with nothing on it sits on step zero" do
    cal = build([[Date.new(2026, 9, 14), 12, 3, 2]])

    said = cal.cells.find { |cell| cell.on == Date.new(2026, 9, 14) }
    quiet = cal.cells.find { |cell| cell.on == Date.new(2026, 9, 15) }

    assert_operator said.step, :>, 0
    assert_equal 0, quiet.step
    assert_equal 1, cal.active_days
  end

  test "days before the first post are not called quiet" do
    first = Date.new(2026, 3, 9)
    cal = build([[first, 4, 1, 0]], first_post_on: first)

    assert cal.cells.find { |cell| cell.on == first - 1 }.before?
    assert cal.cells.find { |cell| cell.on == first }.measured?
  end

  test "days after today are neither quiet nor measured" do
    today = Date.new(2026, 9, 18)
    cal = build([], today: today)

    assert cal.cells.find { |cell| cell.on == today + 1 }.future?
    assert cal.cells.find { |cell| cell.on == today }.measured?
  end

  test "the run spans the columns its days fall in" do
    cal = build([], run_from: Date.new(2026, 9, 1), run_to: Date.new(2026, 9, 18))
    from, to = cal.run_columns

    assert_operator from, :<=, to
    assert_equal cal.column_of(Date.new(2026, 9, 1)), from
    assert_equal 53, to
  end

  test "no run, no rule" do
    assert_nil build([]).run_columns
  end

  test "a day spent where the archive cannot see still counts" do
    on = Date.new(2026, 9, 12)
    cal = Community::Calendar.new(held: [], posted: [[on, 55, 32]],
      window_start: Date.new(2026, 9, 18).end_of_week(:monday) - (53 * 7 - 1),
      window_end: Date.new(2026, 9, 18).end_of_week(:monday), today: Date.new(2026, 9, 18))

    said = cal.cells.find { |cell| cell.on == on }
    assert_operator said.step, :>, 0, "a day only Slack saw must still be coloured"
    assert_equal 55, said.messages
    assert_equal 32, said.in_channels
    assert_equal 23, said.elsewhere
    assert_equal 0, said.rooms
    assert said.unseen?, "the archive holds none of it"
    assert_equal 1, cal.active_days
  end

  test "a day the archive holds but Slack has not published yet stays lit" do
    on = Date.new(2026, 9, 17)
    cal = Community::Calendar.new(held: [[on, 2, 1, 6]], posted: [],
      window_start: Date.new(2026, 9, 18).end_of_week(:monday) - (53 * 7 - 1),
      window_end: Date.new(2026, 9, 18).end_of_week(:monday), today: Date.new(2026, 9, 18))

    said = cal.cells.find { |cell| cell.on == on }
    assert_equal 6, said.messages, "the archive is the floor when analytics lags"
    assert_equal 6, said.in_channels
    assert_equal 0, said.elsewhere
    assert_operator said.step, :>, 0
  end

  test "the archive still supplies the breakdown when it has the day" do
    on = Date.new(2026, 9, 12)
    cal = Community::Calendar.new(held: [[on, 4, 9, 20]], posted: [[on, 20, 20]],
      window_start: Date.new(2026, 9, 18).end_of_week(:monday) - (53 * 7 - 1),
      window_end: Date.new(2026, 9, 18).end_of_week(:monday), today: Date.new(2026, 9, 18))

    said = cal.cells.find { |cell| cell.on == on }
    assert_equal 20, said.messages
    assert_equal 4, said.rooms
    assert_equal 9, said.replies
    assert_equal 0, said.elsewhere
    assert_not said.unseen?
  end

  test "the run follows the days that are lit, not the one it was handed" do
    today = Date.new(2026, 9, 18)
    lit = (0..20).map { |n| [today - n, 5, 5] }
    cal = Community::Calendar.new(held: [], posted: lit,
      window_start: today.end_of_week(:monday) - (53 * 7 - 1),
      window_end: today.end_of_week(:monday), today: today,
      run_from: Date.new(2026, 1, 1), run_to: Date.new(2026, 1, 2))

    assert_equal cal.column_of(today - 20), cal.run_columns.first
    assert_equal cal.column_of(today), cal.run_columns.last
  end

  test "the months cover every column once" do
    cal = build([])

    assert_equal 53, cal.months.sum(&:span)
    assert_equal 1, cal.months.first.from
  end
end
