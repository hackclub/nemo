require "test_helper"

class CaseChatPresenceChannelTest < ActionCable::Channel::TestCase
  setup do
    @was = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @kase = make_case
  end

  teardown { Rails.cache = @was }

  test "somebody who may read the case is counted as here, and leaves cleanly" do
    hold_role!("UME", "community_manager")
    stub_connection(user_id: "UME")

    subscribe(case_id: @kase.id)

    assert subscription.confirmed?
    assert_equal %w[UME], Fd::ChatPresence.here(@kase.id)

    travel 100.seconds do
      assert_empty Fd::ChatPresence.here(@kase.id), "no beat, so gone"
      perform :beat
      assert_equal %w[UME], Fd::ChatPresence.here(@kase.id), "a beat brings them back"
    end

    unsubscribe
    assert_empty Fd::ChatPresence.here(@kase.id)
  end

  test "somebody with no role is turned away and never counted" do
    Account.find_or_create_by!(user_id: "UNOBODY")
    stub_connection(user_id: "UNOBODY")

    subscribe(case_id: @kase.id)

    assert subscription.rejected?
    assert_empty Fd::ChatPresence.here(@kase.id)
  end

  test "a case that does not exist is turned away" do
    hold_role!("UME", "community_manager")
    stub_connection(user_id: "UME")

    subscribe(case_id: 0)

    assert subscription.rejected?
  end
end
