require "test_helper"

class Fd::ChatPresenceTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @was = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @kase = make_case
  end

  teardown { Rails.cache = @was }

  test "arriving and leaving keeps the list of who is here" do
    Fd::ChatPresence.arrive(@kase.id, "UME")
    Fd::ChatPresence.arrive(@kase.id, "UYOU")
    assert_equal %w[UME UYOU], Fd::ChatPresence.here(@kase.id).sort

    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_equal %w[UYOU], Fd::ChatPresence.here(@kase.id)
  end

  test "two tabs of one person count as here until both are gone" do
    2.times { Fd::ChatPresence.arrive(@kase.id, "UME") }
    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_equal %w[UME], Fd::ChatPresence.here(@kase.id)

    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_empty Fd::ChatPresence.here(@kase.id)
  end

  test "leaving a case nobody was on does not go negative" do
    Fd::ChatPresence.leave(@kase.id, "UME")
    assert_empty Fd::ChatPresence.here(@kase.id)
  end

  test "somebody whose tab died without saying goodbye drops off once they stop beating" do
    Fd::ChatPresence.arrive(@kase.id, "UME")
    Fd::ChatPresence.arrive(@kase.id, "UYOU")

    travel 60.seconds do
      Fd::ChatPresence.beat(@kase.id, "UYOU")
      assert_equal %w[UME UYOU], Fd::ChatPresence.here(@kase.id).sort
    end

    travel 100.seconds do
      assert_equal %w[UYOU], Fd::ChatPresence.here(@kase.id), "UME never beat again"
    end
  end

  test "an entry written before heartbeats is treated as gone, not as an error" do
    Rails.cache.write("chat_presence/#{@kase.id}", { "UOLD" => 1 })
    assert_empty Fd::ChatPresence.here(@kase.id)

    Fd::ChatPresence.arrive(@kase.id, "UME")
    assert_equal %w[UME], Fd::ChatPresence.here(@kase.id)
  end

  test "a beat from somebody the cache forgot puts them back" do
    Fd::ChatPresence.beat(@kase.id, "UME")
    assert_equal %w[UME], Fd::ChatPresence.here(@kase.id)
  end

  test "only a change in who is here is broadcast" do
    assert_broadcasts("case_#{@kase.id}_chat", 1) { Fd::ChatPresence.arrive(@kase.id, "UME") }
    assert_broadcasts("case_#{@kase.id}_chat", 0) { Fd::ChatPresence.beat(@kase.id, "UME") }
    assert_broadcasts("case_#{@kase.id}_chat", 1) { Fd::ChatPresence.leave(@kase.id, "UME") }
  end
end
