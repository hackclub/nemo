require "test_helper"

class Fd::ChatPresenceTest < ActiveSupport::TestCase
  setup do
    @was = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @kase = make_case
  end

  teardown { Rails.cache = @was }

  test "arriving and leaving keeps the list of who is here" do
    Fd::ChatPresence.arrive(@kase.id, "UME")
    Fd::ChatPresence.arrive(@kase.id, "UYOU")
    assert_equal %w[UME UYOU], Fd::ChatPresence.here(@kase.id).keys.sort

    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_equal %w[UYOU], Fd::ChatPresence.here(@kase.id).keys
  end

  test "two tabs of one person count as here until both are gone" do
    2.times { Fd::ChatPresence.arrive(@kase.id, "UME") }
    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_equal %w[UME], Fd::ChatPresence.here(@kase.id).keys

    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_empty Fd::ChatPresence.here(@kase.id)
  end

  test "leaving a case nobody was on does not go negative" do
    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_empty Fd::ChatPresence.here(@kase.id)
  end

  test "every change is broadcast to the case's stream" do
    assert_broadcasts("case_#{@kase.id}_chat", 1) { Fd::ChatPresence.arrive(@kase.id, "UME") }
  end
end
