require "test_helper"

class Fd::CaseChatBroadcastTest < ActiveSupport::TestCase
  test "a root case streams to just its own channel" do
    root = make_case

    broadcast = Fd::CaseChatBroadcast.new(root.id)

    assert_equal [root.id], broadcast.send(:streamed_to)
  end

  test "a case merged into another also reaches the root's channel" do
    root = make_case(opened_at: 2.days.ago)
    folded = make_case(opened_at: 1.day.ago)
    folded.update!(resolved_at: Time.current, resolution: "duplicate", duplicate_of: root.id)

    broadcast = Fd::CaseChatBroadcast.new(folded.id)

    assert_equal [folded.id, root.id], broadcast.send(:streamed_to)
  end

  test "a chain of merges still resolves to the true root's channel" do
    root = make_case(opened_at: 3.days.ago)
    middle = make_case(opened_at: 2.days.ago)
    leaf = make_case(opened_at: 1.day.ago)
    middle.update!(resolved_at: Time.current, resolution: "duplicate", duplicate_of: root.id)
    leaf.update!(resolved_at: Time.current, resolution: "duplicate", duplicate_of: middle.id)

    broadcast = Fd::CaseChatBroadcast.new(leaf.id)

    assert_equal [leaf.id, root.id], broadcast.send(:streamed_to)
  end

  test "a case that no longer exists is not broadcast at all" do
    assert_nil Fd::CaseChatBroadcast.of(-1)
  end
end
