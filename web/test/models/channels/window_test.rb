require "test_helper"

class Channels::WindowTest < ActiveSupport::TestCase
  PULLED_START = Date.new(2026, 8, 7)
  PULLED_END = Date.new(2026, 9, 5)
  EDGE = Date.new(2026, 9, 5)

  def build(days, pulled_start: PULLED_START, pulled_end: PULLED_END, edge: EDGE)
    Channels::Window.new(days: days, pulled_start: pulled_start,
      pulled_end: pulled_end, edge: edge)
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
end
