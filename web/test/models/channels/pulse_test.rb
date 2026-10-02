require "test_helper"

class Channels::PulseTest < ActiveSupport::TestCase
  def day(ds, **rest)
    Analytics::MartChannelDay.new({ ds: Date.parse(ds), messages: 0, member_messages: 0,
                                    bot_messages: 0, authors: 0, questions: 0,
                                    questions_with_replies: 0, thread_replies: 0,
                                    thread_roots: 0, replies_on_roots: 0, reactions: 0,
                                    unreacted: 0, text_length_total: 0, with_link: 0,
                                    with_file: 0, emoji_only: 0, substantive: 0,
                                    with_mention: 0 }.merge(rest))
  end

  def build(rows, from: "2026-09-01", to: "2026-09-03")
    Channels::Pulse.new(channel_id: "C1", from: Date.parse(from), to: Date.parse(to), rows: rows)
  end

  test "a measure is the sum of the days in the range" do
    pulse = build([day("2026-09-01", member_messages: 10, messages: 12),
                   day("2026-09-02", member_messages: 5, messages: 6)])

    assert_equal 15, pulse.member_messages
    assert_equal 18, pulse.messages
  end

  test "distinct authors are averaged over the days, never added up" do
    pulse = build([day("2026-09-01", authors: 10), day("2026-09-02", authors: 20)])

    assert_equal 15, pulse.posters_per_day
  end

  test "an empty range has no average rather than a zero" do
    assert_nil build([]).posters_per_day
  end

  test "a share is nil when the denominator is empty" do
    assert_nil build([]).answered_share
    assert_equal 50.0, build([day("2026-09-01", questions: 4, questions_with_replies: 2)])
      .answered_share
  end

  test "a daily share is nil on a day that carried no message" do
    pulse = build([day("2026-09-02", messages: 10, with_link: 4)])

    assert_equal [nil, 40.0, nil], pulse.share_series(:with_link)
  end

  test "a daily share divides by that day alone" do
    pulse = build([day("2026-09-01", messages: 4, substantive: 1),
                   day("2026-09-02", messages: 10, substantive: 9)])

    assert_equal [25.0, 90.0, nil], pulse.share_series(:substantive)
  end

  test "labels line up one for one with the series" do
    pulse = build([day("2026-09-02", messages: 1)])

    assert_equal pulse.series.size, pulse.labels.size
    assert_equal "2026-09-01", pulse.labels.first
  end

  test "the series carries a row for every day, including the silent ones" do
    pulse = build([day("2026-09-02", member_messages: 5)])
    series = pulse.series

    assert_equal 3, series.size
    assert_equal [0, 5, 0], series.map(&:member_messages)
    assert_equal Date.parse("2026-09-01"), series.first.ds
  end

  test "the series carries reactions for every day" do
    pulse = build([day("2026-09-02", reactions: 7)])

    assert_equal [0, 7, 0], pulse.series.map(&:reactions)
  end

  test "the prior window is the same length, ending the day before" do
    pulse = build([], from: "2026-09-08", to: "2026-09-14")

    assert_equal 7, pulse.days
    assert_equal Date.parse("2026-09-01"), pulse.prior.from
    assert_equal Date.parse("2026-09-07"), pulse.prior.to
  end

  test "change is nil when there is nothing to measure against" do
    pulse = build([day("2026-09-01", member_messages: 10)])
    pulse.prior.instance_variable_set(:@rows, [])

    assert_nil pulse.change(:member_messages)
  end

  test "change reads as a percentage against the window before" do
    pulse = build([day("2026-09-01", member_messages: 150)])
    pulse.prior.instance_variable_set(:@rows, [day("2026-08-29", member_messages: 100)])

    assert_equal 50.0, pulse.change(:member_messages)
  end

  test "the posters change compares the daily average, not a sum" do
    pulse = build([day("2026-09-01", authors: 12), day("2026-09-02", authors: 18)])
    pulse.prior.instance_variable_set(:@rows, [day("2026-08-30", authors: 10)])

    assert_equal 15, pulse.posters_per_day
    assert_equal 50.0, pulse.posters_change
  end

  test "the posters change is nil when either window is empty" do
    pulse = build([day("2026-09-01", authors: 12)])
    pulse.prior.instance_variable_set(:@rows, [])

    assert_nil pulse.posters_change
  end

  test "replies per thread needs a thread to have been started" do
    assert_nil build([day("2026-09-01", replies_on_roots: 9)]).replies_per_thread
    assert_equal 3.0, build([day("2026-09-01", thread_roots: 3, replies_on_roots: 9)])
      .replies_per_thread
  end

  test "average length is per message, not per day" do
    pulse = build([day("2026-09-01", messages: 2, text_length_total: 100),
                   day("2026-09-02", messages: 2, text_length_total: 300)])

    assert_equal 100, pulse.average_length
  end
end
