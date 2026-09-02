require "test_helper"

class CommunityAccessTest < ActionDispatch::IntegrationTest
  setup do
    @boss = Staff.create!(user_id: "UCABOSS", community_manager: true)
  end

  def holding_nothing
    Staff.create!(user_id: "UCANONE")
  end

  def reading(role)
    staff = Staff.create!(user_id: "UCA#{role.upcase}")
    Community::Grant.give!(staff.user_id, role: role, by: @boss.user_id)
    staff
  end

  test "somebody holding nothing lands on the front door, not a refusal" do
    sign_in_as(holding_nothing)

    get root_path

    assert_response :success
    assert_select ".card-title", text: "Open to everyone"
  end

  test "somebody holding nothing is kept out of fire engine" do
    sign_in_as(holding_nothing)

    get fd_root_path

    assert_redirected_to root_path
    assert_match(/conduct team/, flash[:alert])
  end

  test "an observer reads the workspace without any fire department grant" do
    sign_in_as(reading("observer"))

    get root_path

    assert_response :success
    assert_select ".card-title", text: "Open to everyone", count: 0,
      message: "an observer gets the real overview, not the front door"
  end

  test "an observer is kept out of the engine" do
    sign_in_as(reading("observer"))

    get engine_path

    assert_redirected_to root_path
  end

  test "a firefighter holds no community access at all" do
    hand = Staff.create!(user_id: "UCAFF")
    Fd::AccessGrant.give!(hand.user_id, role: "firefighter", by: @boss.user_id)

    assert_nil Community::Access.role(hand, "read")
    assert_nil Community::Access.role(hand, "ops")
    assert_not Community::Access.allow?(hand, "analytics.workspace.read")
  end

  test "a community manager holds the top of both ladders without a grant" do
    assert_equal "curator", Community::Access.role(@boss, "read")
    assert_equal "steward", Community::Access.role(@boss, "ops")
    assert Community::Access.allow?(@boss, "ops.engine.sync")
    assert_equal 0, Community::Grant.where(user_id: @boss.user_id).count,
      "the manager is superadmin by role, not by a grant row"
  end

  test "the two ladders are held independently" do
    staff = Staff.create!(user_id: "UCABOTH")
    Community::Grant.give!(staff.user_id, role: "observer", by: @boss.user_id)
    Community::Grant.give!(staff.user_id, role: "steward", by: @boss.user_id)

    assert_equal "observer", Community::Access.role(staff, "read")
    assert_equal "steward", Community::Access.role(staff, "ops")
    assert_not Community::Access.allow?(staff, "analytics.member.read")
    assert Community::Access.allow?(staff, "ops.engine.sync")
  end

  def some_channels(count = 3)
    Analytics::DimChannel.where(archived: false).order(:channel_id).limit(count).to_a
  end

  def open_up(channel, audience)
    Channels::Audience::Setting.create!(channel_id: channel.channel_id,
      audience: audience, set_by: @boss.user_id)
  end

  test "an observer sees only the channels opened to everyone" do
    shown, hidden, = some_channels
    open_up(shown, "everyone")
    open_up(hidden, "shared")
    staff = reading("observer")

    ids = Channels::Audience.for(staff).pluck(:channel_id)

    assert_includes ids, shown.channel_id
    assert_not_includes ids, hidden.channel_id, "shared is for analysts, not observers"
  end

  test "an analyst sees shared channels and the ones granted to them" do
    shared, granted, other = some_channels
    open_up(shared, "shared")
    staff = reading("analyst")
    Channels::Audience::Grant.create!(user_id: staff.user_id, channel_id: granted.channel_id,
      granted_by: @boss.user_id, granted_at: Time.current)

    ids = Channels::Audience.for(staff).pluck(:channel_id)

    assert_includes ids, shared.channel_id
    assert_includes ids, granted.channel_id
    assert_not_includes ids, other.channel_id
  end

  test "a channel outside your audience is missing, not forbidden" do
    hidden = some_channels(1).first
    sign_in_as(reading("analyst"))

    get channel_path(hidden.channel_id)

    assert_response :not_found,
      "a 403 would confirm the channel exists, which is the thing being hidden"
  end

  test "filters are unavailable while looking at every channel" do
    sign_in_as(reading("analyst"))

    get channels_path(scope: "all", f: ["never_posted"])

    assert_response :success
    assert_select ".btn.is-off", text: /Filter/
    assert_select ".pill", count: 0, message: "a filter plus a count reads the hidden numbers"
  end

  test "an observer is told member names are withheld, not shown them" do
    sign_in_as(reading("observer"))

    get active_journey_path

    assert_response :success
    assert_select ".empty-title", text: "Member names are not shown to you"
  end

  test "an analyst sees the top posters" do
    sign_in_as(reading("analyst"))

    get active_journey_path

    assert_response :success
    assert_select ".empty-title", text: "Member names are not shown to you", count: 0
  end

  def operating(role)
    staff = Staff.create!(user_id: "UCAOP#{role.upcase}")
    Community::Grant.give!(staff.user_id, role: role, by: @boss.user_id)
    staff
  end

  def priceable_channel
    Analytics::DimChannel.where(archived: false).order(:channel_id).find do |channel|
      ChannelBackfill.estimate(channel).to_i.positive?
    end
  end

  test "an analyst cannot queue a backfill, however cheap" do
    channel = some_channels(1).first
    open_up(channel, "everyone")
    sign_in_as(reading("analyst"))

    assert_no_difference -> { ChannelBackfill.count } do
      post opt_in_channel_path(channel.channel_id)
    end

    assert_match(/operator only/, flash[:alert])
  end

  test "an operator is stopped by the ceiling, and told what it would cost" do
    channel = priceable_channel
    skip "the seed priced no channel" if channel.nil?
    open_up(channel, "everyone")
    Engine::Setting.set!("engine", "backfill_ceiling", "0", by: @boss.user_id)
    sign_in_as(operating("operator"))

    assert_no_difference -> { ChannelBackfill.count } do
      post opt_in_channel_path(channel.channel_id)
    end

    assert_match(/needs a steward/, flash[:alert])
  end

  test "a steward is not stopped by the ceiling" do
    channel = priceable_channel
    skip "the seed priced no channel" if channel.nil?
    open_up(channel, "everyone")
    Engine::Setting.set!("engine", "backfill_ceiling", "0", by: @boss.user_id)
    sign_in_as(operating("steward"))

    assert_difference -> { ChannelBackfill.count }, 1 do
      post opt_in_channel_path(channel.channel_id)
    end
  end

  test "a new grant in one family retires only that family" do
    staff = Staff.create!(user_id: "UCASWAP")
    Community::Grant.give!(staff.user_id, role: "observer", by: @boss.user_id)
    Community::Grant.give!(staff.user_id, role: "operator", by: @boss.user_id)
    Community::Grant.give!(staff.user_id, role: "analyst", by: @boss.user_id)

    assert_equal "analyst", Community::Access.role(staff, "read")
    assert_equal "operator", Community::Access.role(staff, "ops"),
      "granting a read role must not disturb the ops ladder"
    assert_equal 2, Community::Grant.live.where(user_id: staff.user_id).count
  end
end
