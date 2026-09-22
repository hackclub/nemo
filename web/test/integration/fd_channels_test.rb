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
end
