require "test_helper"

class FdChannelsOverviewTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @channel = Analytics::DimChannel.where(archived: false).order(:channel_id).first
    skip "the corpus has no channel" if @channel.nil?
    @other = Analytics::DimChannel.where(archived: false).order(:channel_id).second
  end

  def guard!(kind, channel_id = @channel.channel_id, **over)
    Fd::ChannelGuard.create!({ kind: kind, channel_id: channel_id,
                               opened_by: "UME" }.merge(over))
  end

  test "the overview lists every live guard" do
    guard! Fd::ChannelGuard::READONLY
    guard! Fd::ChannelGuard::SLOWMODE, settings: { "seconds" => 30, "threads" => true }

    get fd_channels_path

    assert_response :success
    assert_select ".people-list > .line-row", 2
    assert_match(/Read-only/, response.body)
    assert_match(/30 seconds between messages, threads too/, response.body)
  end

  test "a read-only guard that also catches threads says so" do
    guard! Fd::ChannelGuard::READONLY, settings: { "threads" => true }

    get fd_channels_path

    assert_match(/nobody may post, threads too/, response.body)
  end

  test "a lifted guard is not listed" do
    one = guard!(Fd::ChannelGuard::READONLY)
    one.update!(state: "lifted", lifted_at: Time.current, lifted_by: "UME")

    get fd_channels_path

    assert_select ".people-list > .line-row", false
    assert_match(/No guard is on/, response.body)
  end

  test "each kind counts itself in the tabs" do
    guard! Fd::ChannelGuard::READONLY
    guard! Fd::ChannelGuard::ACCOUNT_AGE, settings: { "min_age_days" => 7 }

    get fd_channels_path

    assert_select %(a[href=?] .view-count), fd_channels_path(kind: "readonly"), text: "1"
    assert_select %(a[href=?] .view-count), fd_channels_path(kind: "account_age"), text: "1"
    assert_select %(a[href=?] .view-count), fd_channels_path(kind: "slowmode"), text: "0"
  end

  test "a kind narrows the table to itself" do
    skip "the corpus has one channel" if @other.nil?
    guard! Fd::ChannelGuard::READONLY
    guard! Fd::ChannelGuard::SLOWMODE, @other.channel_id, settings: { "seconds" => 30 }

    get fd_channels_path(kind: "slowmode")

    assert_select ".people-list > .line-row", 1
    assert_match(/30 seconds between messages/, response.body)
  end

  test "a kind nobody uses says so" do
    get fd_channels_path(kind: "slowmode")

    assert_response :success
    assert_match(/None on/, response.body)
  end

  test "a bot allow list counts what it allows" do
    guard!(Fd::ChannelGuard::BOT_ALLOWLIST)
      .allows.create!(subject_id: "B0CACHET", label: "Cachet", added_by: "UME")

    get fd_channels_path

    assert_match(/1 bot allowed/, response.body)
  end

  test "a row links to the tab that guard lives on" do
    guard! Fd::ChannelGuard::SLOWMODE, settings: { "seconds" => 30 }

    get fd_channels_path

    assert_select %(.line-row a[href=?]),
      fd_channel_path(@channel.channel_id, tab: "slowmode")
  end

  test "an unknown kind falls back to every guard" do
    guard! Fd::ChannelGuard::READONLY

    get fd_channels_path(kind: "nonsense")

    assert_select ".people-list > .line-row", 1
  end
end
