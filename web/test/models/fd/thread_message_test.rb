require "test_helper"

class Fd::ThreadMessageTest < ActiveSupport::TestCase
  test "the app can read messages but never write one" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Fd::ThreadMessage.create!(channel_id: "C0LOUNGE", thread_ts: "1754487721.123456",
        message_ts: "1754487721.123456", is_root: true, author_user_id: "UDEX",
        posted_at: Time.current, body: "written by the dashboard")
    end
  end

  test "asking for the messages of nothing asks the database nothing" do
    assert_empty Fd::ThreadMessage.for_threads([]).to_a
  end

  test "several threads are read in one pass, oldest first" do
    kase = make_case
    lounge = Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0LOUNGE",
      thread_ts: "1754487721.123456", added_by: "UFF1", is_primary: true)
    ship = Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0SHIP",
      thread_ts: "1754570000.100000", added_by: "UFF1")

    sql = Fd::ThreadMessage.for_threads([lounge, ship]).to_sql

    assert_includes sql, "C0LOUNGE"
    assert_includes sql, "C0SHIP"
    assert_equal 1, sql.scan(/ORDER BY/).size
    assert_empty Fd::ThreadMessage.for_threads([lounge, ship]).to_a
  end

  test "a thread attached twice is only asked for once" do
    kase = make_case
    twice = Array.new(2) do
      Fd::CaseThread.new(channel_id: "C0LOUNGE", thread_ts: "1754487721.123456",
        case_id: kase.id, added_by: "UFF1")
    end

    assert_equal 1, Fd::ThreadMessage.for_threads(twice).to_sql.scan("C0LOUNGE").size
  end
end
