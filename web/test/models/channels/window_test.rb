require "test_helper"

class Channels::WindowTest < ActiveSupport::TestCase
  PULLED_START = Date.new(2026, 8, 7)
  PULLED_END = Date.new(2026, 9, 5)
  EDGE = Date.new(2026, 9, 5)

  def build(days, pulled_start: PULLED_START, pulled_end: PULLED_END, edge: EDGE,
            start_on: nil, end_on: nil)
    Channels::Window.new(days: days, pulled_start: pulled_start,
      pulled_end: pulled_end, edge: edge, start_on: start_on, end_on: end_on)
  end

  test "the pulled window is measured inclusively and offered as a choice" do
    w = build(nil)

    assert_equal 30, w.pulled_days
    assert_equal [7, 30, 90], w.choices
  end

  test "a pulled window that matches no preset is offered alongside them" do
    w = build(nil, pulled_start: Date.new(2026, 9, 2), pulled_end: Date.new(2026, 9, 4))

    assert_equal 3, w.pulled_days
    assert_equal [3, 7, 30, 90], w.choices
  end

  test "no asked range falls back to the pulled window and reads the range mart" do
    w = build(nil)

    assert_equal 30, w.days
    assert w.pulled?
    assert_nil w.join
    assert_nil w.asked
    assert_equal "r.messages_posted_by_members", w.measure_sql
    assert_empty w.measures
  end

  test "asking for the pulled length keeps the fast path" do
    assert build("30").pulled?, "30 is the pulled window, so it must not roll up"
  end

  test "a preset rolls up the daily mart over a window ending at the edge" do
    w = build("7")

    assert_not w.pulled?
    assert_equal 7, w.days
    assert_equal Date.new(2026, 8, 30), w.start_date
    assert_equal EDGE, w.end_date
    assert_equal 7, w.asked
    assert_equal "a.range_messages", w.measure_sql
    assert_equal({ "messages" => "a.range_messages" }, w.measures)
  end

  test "the roll-up binds its dates rather than pasting them" do
    sql = build("90").join

    assert_includes sql, "sum(messages_posted_by_members) AS range_messages"
    assert_includes sql, "BETWEEN '2026-06-08' AND '2026-09-05'"
    assert_includes sql, "GROUP BY channel_id"
  end

  test "a range nobody offered is refused" do
    %w[1 45 1000 0 -7 abc].each do |bad|
      assert_equal 30, build(bad).days, "#{bad.inspect} must not become a window"
    end
  end

  test "with no daily rows every choice stays on the pulled window" do
    w = build("90", edge: nil)

    assert w.pulled?
    assert_nil w.join
    assert_equal PULLED_START, w.start_date
    assert_equal PULLED_END, w.end_date
    assert_not w.adjustable?, "a control nothing can answer must not be offered"
  end

  test "the control is offered once there are days to roll up" do
    assert build(nil).adjustable?
  end

  test "with no pulled window the presets are all there is" do
    w = build(nil, pulled_start: nil, pulled_end: nil)

    assert_nil w.pulled_days
    assert_equal [7, 30, 90], w.choices
    assert_equal 7, w.days
    assert_not w.pulled?
  end

  test "the selected column carries the alias the rows partial reads" do
    assert_equal "r.messages_posted_by_members AS range_messages", build(nil).column
    assert_equal "a.range_messages", build("7").column
  end

  test "a custom range wins over any preset and rolls up over its own dates" do
    w = build("7", start_on: Date.new(2026, 8, 20), end_on: Date.new(2026, 8, 29))

    assert w.custom?
    assert_not w.pulled?
    assert_equal Date.new(2026, 8, 20), w.start_date
    assert_equal Date.new(2026, 8, 29), w.end_date
    assert_equal 10, w.days
    assert_includes w.join, "BETWEEN '2026-08-20' AND '2026-08-29'"
  end

  test "a custom range is carried in the query rather than a preset" do
    w = build(nil, start_on: Date.new(2026, 8, 20), end_on: Date.new(2026, 8, 29))

    assert_nil w.asked
    assert_equal Date.new(2026, 8, 20), w.asked_start
    assert_equal Date.new(2026, 8, 29), w.asked_end
  end

  test "a preset carries no custom dates" do
    w = build("7")

    assert_not w.custom?
    assert_nil w.asked_start
    assert_nil w.asked_end
  end

  test "a custom range past the measured edge is pulled back to it" do
    w = build(nil, start_on: Date.new(2020, 1, 1), end_on: Date.new(2030, 1, 1))

    assert_equal w.ceiling, w.end_date
    assert_equal w.floor, w.start_date
  end

  test "a custom range given backwards never ends before it starts" do
    w = build(nil, start_on: Date.new(2026, 9, 4), end_on: Date.new(2026, 8, 20))

    assert_operator w.start_date, :<=, w.end_date
  end

  test "only one end of a custom range is enough" do
    w = build(nil, end_on: Date.new(2026, 8, 29))

    assert w.custom?
    assert_equal Date.new(2026, 8, 29), w.end_date
  end
end
