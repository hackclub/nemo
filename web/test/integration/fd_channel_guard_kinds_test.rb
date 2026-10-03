require "test_helper"

class FdChannelGuardKindsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @channel = Analytics::DimChannel.where(archived: false).order(:channel_id).first
    skip "the corpus has no channel" if @channel.nil?
    @id = @channel.channel_id
  end

  def guard!(kind, **settings)
    Fd::ChannelGuard.create!(kind: kind, channel_id: @id, opened_by: "UME",
      settings: settings.stringify_keys)
  end

  def live(kind) = Fd::ChannelGuard.live_for(@id, kind: kind)

  def turn_on(kind, **params)
    post fd_channel_guard_path(@id, kind), params: params
  end

  def tune(kind, **params)
    patch fd_channel_guard_path(@id, kind), params: params
  end

  test "every tab opens" do
    Fd::ChannelsController::TABS.each do |tab|
      get fd_channel_path(@id, tab: tab)
      assert_response :success, "#{tab} did not open"
    end
  end

  test "an unknown tab falls back to the first" do
    get fd_channel_path(@id, tab: "sideways")

    assert_response :success
    assert_match(/Guards/, response.body)
  end

  test "read-only is turned on and off on its own" do
    turn_on("readonly")

    assert live("readonly")
    assert_nil live("bot_allowlist")

    delete fd_channel_guard_path(@id, "readonly")
    assert_nil live("readonly")
  end

  test "all four kinds stand at once on one channel" do
    Fd::ChannelGuard::KINDS.each do |kind|
      guard!(kind, seconds: 30, min_age_days: 7)
    end

    assert_equal 4, Fd::ChannelGuard.live.where(channel_id: @id).count
  end

  test "a kind that is not a kind is refused" do
    turn_on("sideways")

    assert_equal 0, Fd::ChannelGuard.live.where(channel_id: @id).count
    assert_match(/not a valid guard kind/, flash[:alert])
  end

  test "slow mode keeps the seconds it was given" do
    turn_on("slowmode", seconds: "45", threads: "1")
    guard = live("slowmode")

    assert_equal 45, guard.seconds
    assert guard.threads?
  end

  test "slow mode without threads leaves them out" do
    turn_on("slowmode", seconds: "45")

    assert_not live("slowmode").threads?
  end

  test "the switch turns slow mode on with an interval to start from" do
    turn_on("slowmode")

    assert_equal Fd::ChannelGuard::SECONDS_TO_START, live("slowmode").seconds
    assert_nil flash[:alert]
  end

  test "the switch turns the age gate on with days to start from" do
    turn_on("account_age")

    assert_equal Fd::ChannelGuard::DAYS_TO_START, live("account_age").min_age_days
    assert_nil flash[:alert]
  end

  test "slow mode refuses a interval outside the range" do
    turn_on("slowmode", seconds: "0")
    assert_nil live("slowmode")

    turn_on("slowmode", seconds: "99999")
    assert_nil live("slowmode")
    assert_match(/from 1 to/, flash[:alert])
  end

  test "slow mode is retuned in place and audited" do
    turn_on("slowmode", seconds: "30")
    tune("slowmode", seconds: "90", threads: "1")

    assert_equal 90, live("slowmode").seconds
    assert_equal 1, Fd::AuditEntry.where(entity_type: "channel_guard", verb: "tuned").count
  end

  test "an account age gate keeps its days" do
    turn_on("account_age", min_age_days: "7")

    assert_equal 7, live("account_age").min_age_days
  end

  test "an account age outside the range is refused" do
    turn_on("account_age", min_age_days: "0")

    assert_nil live("account_age")
    assert_match(/from 1 to/, flash[:alert])
  end

  test "tuning a kind that is not on is refused" do
    tune("slowmode", seconds: "30")

    assert_match(/not guarded that way/, flash[:alert])
  end

  test "a member is let past read-only" do
    guard!("readonly")
    post fd_channel_allows_path(@id, "readonly"), params: { subject_ids: ["USOMEBODY"] }

    assert_equal ["USOMEBODY"], live("readonly").allows.pluck(:subject_id)
  end

  test "an allow lands on the kind it was added under" do
    guard!("readonly")
    guard!("slowmode", seconds: 30)
    post fd_channel_allows_path(@id, "readonly"), params: { subject_ids: ["USOMEBODY"] }

    assert_equal 1, live("readonly").allows.count
    assert_equal 0, live("slowmode").allows.count
  end

  test "an allow on a kind nobody guards is refused" do
    post fd_channel_allows_path(@id, "readonly"), params: { subject_ids: ["USOMEBODY"] }

    assert_match(/not guarded/, flash[:alert])
  end

  test "the overview names every kind" do
    get fd_channel_path(@id, tab: "overview")

    assert_match(/Bot allow list/, response.body)
    assert_match(/Read-only/, response.body)
    assert_match(/Slow mode/, response.body)
    assert_match(/New accounts/, response.body)
  end

  test "activity sits under the kind it belongs to" do
    bots = guard!("bot_allowlist")
    ro = guard!("readonly")
    Fd::ChannelGuardEvent.create!(guard_id: bots.id, channel_id: @id,
      subject_id: "B0CACHET", verb: "kicked")
    Fd::ChannelGuardEvent.create!(guard_id: ro.id, channel_id: @id,
      subject_id: "USOMEBODY", verb: "deleted")

    get fd_channel_path(@id, tab: "bots")
    assert_match(/B0CACHET/, response.body)
    assert_no_match(/USOMEBODY/, response.body)

    get fd_channel_path(@id, tab: "readonly")
    assert_match(/USOMEBODY/, response.body)
    assert_no_match(/B0CACHET/, response.body)
  end

  test "activity outlives the guard that recorded it" do
    guard = guard!("readonly")
    Fd::ChannelGuardEvent.create!(guard_id: guard.id, channel_id: @id,
      subject_id: "USOMEBODY", verb: "deleted")
    delete fd_channel_guard_path(@id, "readonly")
    get fd_channel_path(@id, tab: "readonly")

    assert_match(/USOMEBODY/, response.body)
  end

  test "a tab with no activity shows no activity card" do
    guard!("readonly")
    get fd_channel_path(@id, tab: "readonly")

    assert_no_match(/Activity/, response.body)
  end

  test "somebody without channel.guard cannot turn a kind on" do
    drop_roles!("UME")
    hold_role!("UME", "gardener")
    turn_on("readonly")

    assert_equal 0, Fd::ChannelGuard.live.where(channel_id: @id).count
  end
end
