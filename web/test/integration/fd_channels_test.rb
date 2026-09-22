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
      channel_id: @channel.channel_id, opened_by: "UME")
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

  test "turning the guard on records who did it" do
    post fd_channel_guard_path(@channel.channel_id)

    guard = Fd::ChannelGuard.live_for(@channel.channel_id)
    assert_not_nil guard
    assert_equal "UME", guard.opened_by
    assert_nil guard.reason
    assert Fd::AuditEntry.where(entity_type: "channel_guard", entity_id: guard.id,
      verb: "opened").exists?
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

  test "allowing a bot records who vouched for it" do
    guard = guard!

    post fd_channel_allows_path(@channel.channel_id),
      params: { subject_ids: ["B0CACHET"], reason: "posts the avatars" }

    allow = guard.allows.find_by(subject_id: "B0CACHET")
    assert_not_nil allow
    assert_equal "UME", allow.added_by
    assert_equal "posts the avatars", allow.reason
    assert Fd::AuditEntry.where(entity_type: "channel_allow", entity_id: guard.id,
      verb: "added").exists?
  end

  test "allowing the same bot twice leaves one row" do
    guard = guard!
    2.times do
      post fd_channel_allows_path(@channel.channel_id), params: { subject_ids: ["B0CACHET"] }
    end

    assert_equal 1, guard.allows.where(subject_id: "B0CACHET").count
  end

  test "an id that is not a member id is refused" do
    guard = guard!

    post fd_channel_allows_path(@channel.channel_id), params: { subject_ids: ["not-an-id"] }

    assert_equal 0, guard.allows.count
  end

  test "nothing can be allowed on a channel nobody guards" do
    post fd_channel_allows_path(@channel.channel_id), params: { subject_ids: ["B0CACHET"] }

    assert_equal 0, Fd::ChannelGuardAllow.count
  end

  test "removing a bot takes it off the list and lands in the trail" do
    guard = guard!
    guard.allows.create!(subject_id: "B0CACHET", label: "Cachet", added_by: "UME")

    delete fd_channel_allow_path(@channel.channel_id, "B0CACHET")

    assert_equal 0, guard.allows.count
    assert Fd::AuditEntry.where(entity_type: "channel_allow", entity_id: guard.id,
      verb: "removed").exists?
  end

  test "the bot picker looks for bots, the member picker does not" do
    bot = Fd::Member.live.where(is_bot: false).first
    skip "the corpus has no member" if bot.nil?

    found = Fd::Member.search(bot.name, live_only: true, bots: true).map(&:user_id)
    assert_not_includes found, bot.user_id
  end

  test "somebody without channel.guard cannot turn one on" do
    them = hold_role!("UFF9", "firefighter")
    move_capability!("firefighter", "channel.guard", false, by: "UME")
    sign_in_as(them)

    post fd_channel_guard_path(@channel.channel_id), params: { reason: "app spam" }

    assert_nil Fd::ChannelGuard.live_for(@channel.channel_id)
  end
end
