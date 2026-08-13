require "test_helper"

class Fd::CaseThreadsTest < ActiveSupport::TestCase
  Said = Struct.new(:channel_id, :thread_ts, :is_root, :reply_count, keyword_init: true) do
    def root? = is_root
  end

  setup do
    @kase = make_case
  end

  def attach(channel, ts, **attrs)
    Fd::CaseThread.create!({
      case_id: @kase.id, channel_id: channel, thread_ts: ts, added_by: "UFF1"
    }.merge(attrs))
  end

  def said(channel, ts, root: false, reply_count: nil)
    Said.new(channel_id: channel, thread_ts: ts, is_root: root, reply_count: reply_count)
  end

  def locked(channel)
    Fd::Action.new(type_key: "locked_thread", details: { "channel_id" => channel })
  end

  test "the FD thread comes first, then the one it started in" do
    later = attach("C0SHIP", "3.3", added_at: 3.minutes.ago)
    started = attach("C0LOUNGE", "1.1", is_primary: true, added_at: 2.minutes.ago)
    internal = attach("C0HQ", "2.2", kind: "internal", added_at: 1.minute.ago)

    order = Fd::CaseThreads.for([later, started, internal]).map(&:id)
    assert_equal [internal.id, started.id, later.id], order
  end

  test "a locked thread is the one an action names, not every thread" do
    ship = attach("C0SHIP", "3.3")
    lounge = attach("C0LOUNGE", "1.1", is_primary: true)

    rows = Fd::CaseThreads.for([ship, lounge], actions: [locked("C0SHIP")]).to_a
    assert rows.find { |row| row.id == ship.id }.locked?
    refute rows.find { |row| row.id == lounge.id }.locked?
  end

  test "a reversed lock does not lock anything" do
    ship = attach("C0SHIP", "3.3")
    undone = locked("C0SHIP")
    undone.reversed_at = Time.current

    refute Fd::CaseThreads.for([ship], actions: [undone]).chosen.locked?
  end

  test "messages land on the thread they belong to" do
    lounge = attach("C0LOUNGE", "1.1", is_primary: true)
    ship = attach("C0SHIP", "3.3")
    messages = [
      said("C0LOUNGE", "1.1", root: true, reply_count: 4),
      said("C0LOUNGE", "1.1"),
      said("C0SHIP", "3.3", root: true)
    ]

    rows = Fd::CaseThreads.for([lounge, ship], messages: messages).to_a
    assert_equal 2, rows.find { |row| row.id == lounge.id }.held
    assert_equal 1, rows.find { |row| row.id == ship.id }.held
  end

  test "asking for a thread that is not on this case falls back to the first" do
    lounge = attach("C0LOUNGE", "1.1", is_primary: true)
    attach("C0SHIP", "3.3")

    assert_equal lounge.id, Fd::CaseThreads.for(@kase.threads.to_a, asked: "99999").chosen.id
  end
end
