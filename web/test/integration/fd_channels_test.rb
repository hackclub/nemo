require "test_helper"

class FdChannelsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @channel = Analytics::DimChannel.where(archived: false).order(:channel_id).first
    skip "the corpus has no channel" if @channel.nil?
  end

  def guard!
    Fd::ChannelGuard.create!(kind: Fd::ChannelGuard::BOT_ALLOWLIST,
      channel_id: @channel.channel_id, opened_by: "UME", reason: "app spam after a cross-post")
  end

  test "a channel nobody guards still opens" do
    get fd_channel_path(@channel.channel_id)

    assert_response :success
  end

  test "a guarded channel opens with its allow list" do
    guard!.allows.create!(subject_id: "B0CACHET", label: "Cachet", added_by: "UME")

    get fd_channel_path(@channel.channel_id)

    assert_response :success
  end

  test "a channel we have never heard of does not raise" do
    get fd_channel_path("C0NOTHING")

    assert_response :success
  end

  test "a signed out visitor cannot read the channels" do
    reset!
    get fd_channels_path

    assert_redirected_to login_path
  end

  test "turning the guard on records who did it and why" do
    post fd_channel_guard_path(@channel.channel_id), params: { reason: "app spam" }

    guard = Fd::ChannelGuard.live_for(@channel.channel_id)
    assert_not_nil guard
    assert_equal "UME", guard.opened_by
    assert_equal "app spam", guard.reason
    assert Fd::AuditEntry.where(entity_type: "channel_guard", entity_id: guard.id,
      verb: "opened").exists?
  end

  test "a guard needs a reason" do
    post fd_channel_guard_path(@channel.channel_id), params: { reason: "  " }

    assert_nil Fd::ChannelGuard.live_for(@channel.channel_id)
  end

  test "a channel cannot be guarded twice" do
    guard!

    assert_no_difference -> { Fd::ChannelGuard.count } do
      post fd_channel_guard_path(@channel.channel_id), params: { reason: "again" }
    end
  end

  test "lifting keeps the allow list and the guard row" do
    guard = guard!
    guard.allows.create!(subject_id: "B0CACHET", added_by: "UME")

    delete fd_channel_guard_path(@channel.channel_id)

    assert_nil Fd::ChannelGuard.live_for(@channel.channel_id)
    assert_equal "lifted", guard.reload.state
    assert_equal "UME", guard.lifted_by
    assert_not_nil guard.lifted_at
    assert_equal 1, guard.allows.count
  end

  test "lifting a channel nobody guards changes nothing" do
    delete fd_channel_guard_path(@channel.channel_id)

    assert_equal 0, Fd::ChannelGuard.where(channel_id: @channel.channel_id).count
  end

  test "somebody without channel.guard cannot turn one on" do
    them = hold_role!("UFF9", "firefighter")
    move_capability!("firefighter", "channel.guard", false, by: "UME")
    sign_in_as(them)

    post fd_channel_guard_path(@channel.channel_id), params: { reason: "app spam" }

    assert_nil Fd::ChannelGuard.live_for(@channel.channel_id)
  end
end
