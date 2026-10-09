require "test_helper"

class Fd::MemberLinkBroadcastTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  test "a change to the links tells the list to reload" do
    sent = capture_broadcasts(Fd::MemberLinkBroadcast::LIST_STREAM) { Fd::MemberLinkBroadcast.of("*") }

    assert_equal [%(<turbo-stream action="reload_frame" target="member-links-list"></turbo-stream>)], sent
  end

  test "a change to one member refreshes only their open pane" do
    sent = capture_broadcasts(Fd::MemberLinkBroadcast.stream("UONE")) { Fd::MemberLinkBroadcast.of("uone") }

    assert_equal [%(<turbo-stream action="refresh_frame" target="member-links-UONE"></turbo-stream>)], sent
  end

  test "a payload that is not a member is dropped" do
    assert_no_broadcasts(Fd::MemberLinkBroadcast.stream("NOPE")) do
      assert_nil Fd::MemberLinkBroadcast.of("not a member")
    end
  end

  test "the listener hears link changes" do
    assert_includes Fd::ChatListener::CHANNELS, "fd_member_link"
  end
end
