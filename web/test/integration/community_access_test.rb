require "test_helper"

class CommunityAccessTest < ActionDispatch::IntegrationTest
  setup do
    @boss = hold_role!("UCABOSS", "community_manager")
  end

  def holding_nothing
    Account.create!(user_id: "UCANONE")
  end

  def scoped(name, *keys)
    staff = Account.find_or_create_by!(user_id: "UCA#{name.upcase}")
    keys.each do |key|
      Authz::Grant.give!(staff.user_id, kind: "capability", name: key, by: "test")
    end
    Current.forget_roles
    staff
  end

  def reads_names
    scoped("names", "member.read")
  end

  test "somebody holding nothing lands on the front door, not a refusal" do
    sign_in_as(holding_nothing)

    get root_path

    assert_response :success
    assert_select ".card-title", text: "Open to everyone", count: 0,
      message: "the overview is open to every signed-in member now"
  end

  test "somebody holding nothing is kept out of fire engine" do
    sign_in_as(holding_nothing)

    get fd_root_path

    assert_redirected_to root_path
    assert_match(/conduct team/, flash[:alert])
  end

  test "a member reads the workspace without any fire department grant" do
    sign_in_as(holding_nothing)

    get root_path

    assert_response :success
    assert_select ".card-title", text: "Open to everyone", count: 0,
      message: "a member gets the real overview, not the front door"
  end

  test "a member is kept out of the engine" do
    sign_in_as(holding_nothing)

    get engine_path

    assert_redirected_to root_path
  end

  test "a firefighter holds no community grant, but the overview is open to them" do
    hand = hold_role!("UCAFF", "firefighter")

    refute Authz.holds?(hand, "channel.all"), "a firefighter reads no analytics"
    refute Authz.holds?(hand, "engine.read"), "a firefighter runs no engine"
    assert Community::Access.allow?(hand, "analytics.workspace.read"),
      "every signed-in member reads the overview now"
    assert_not Community::Access.allow?(hand, "analytics.member.read")
  end

  test "a manager holds everything without one capability row" do
    assert Community::Access.allow?(@boss, "ops.engine.sync")
    assert Authz.holds?(@boss, "channel.all")
    assert_equal 0, Authz::Grant.live.for_person(@boss.user_id).capabilities.count,
      "the manager is superadmin by role, not by a pile of capability grants"
  end

  test "a role and an extra scope are held independently" do
    staff = hold_role!("UCABOTH", "promethean")
    Authz::Grant.give!(staff.user_id, kind: "capability", name: "engine.sync", by: "test")
    Current.forget_roles

    assert_equal %w[promethean], Authz.roles_held(staff.user_id)
    assert Community::Access.allow?(staff, "ops.engine.sync"), "the extra scope stands alone"
    assert_not Community::Access.allow?(staff, "analytics.member.read"),
      "the scope did not drag anything else in"
  end

  def some_channels(count = 3)
    Analytics::DimChannel.where(archived: false).order(:channel_id).limit(count).to_a
  end

  def open_up(channel, audience)
    Channels::Audience::Setting.create!(channel_id: channel.channel_id,
      audience: audience, set_by: @boss.user_id)
  end

  test "a member sees only the channels opened to everyone" do
    shown, hidden, = some_channels
    open_up(shown, "everyone")
    open_up(hidden, "shared")
    staff = holding_nothing

    ids = Channels::Audience.for(staff).pluck(:channel_id)

    assert_includes ids, shown.channel_id
    assert_not_includes ids, hidden.channel_id, "granted is named people only"
  end

  test "a promethean sees the channels named to them, and nothing else" do
    public_one, granted, other = some_channels
    open_up(public_one, "everyone")
    staff = Account.create!(user_id: "UCAPROM")
    Authz::Grant.give!(staff.user_id, kind: "role", name: "promethean", by: @boss.user_id)
    Channels::Audience::Grant.create!(user_id: staff.user_id, channel_id: granted.channel_id,
      granted_by: @boss.user_id, granted_at: Time.current)
    Current.forget_roles

    ids = Channels::Audience.for(staff).pluck(:channel_id)

    assert_includes ids, granted.channel_id, "the channel named to them"
    assert_includes ids, public_one.channel_id, "and anything public"
    assert_not_includes ids, other.channel_id
  end

  test "a channel grant is enough on its own, channel.read is everyone's by default" do
    _open, granted, = some_channels
    staff = holding_nothing
    Channels::Audience::Grant.create!(user_id: staff.user_id, channel_id: granted.channel_id,
      granted_by: @boss.user_id, granted_at: Time.current)
    Current.forget_roles

    ids = Channels::Audience.for(staff).pluck(:channel_id)

    assert_includes ids, granted.channel_id
  end

  test "a channel outside your audience sends you back with the reason, not an error page" do
    hidden = some_channels(1).first
    sign_in_as(reads_names)

    get channel_path(hidden.channel_id)

    assert_redirected_to channels_path(q: hidden.channel_id)
    assert_match(/not shared with you|channel/, flash[:alert])
  end

  test "filters are unavailable while looking at every channel" do
    sign_in_as(reads_names)

    get channels_path(scope: "all", f: ["never_posted"])

    assert_response :success
    assert_select ".btn.is-off", text: /Filter/
    assert_select ".pill", count: 0, message: "a filter plus a count reads the hidden numbers"
  end

  test "a member is told member names are withheld, not shown them" do
    sign_in_as(holding_nothing)

    get active_journey_path

    assert_response :success
    assert_select ".empty-title", text: "Member names are not shown to you"
  end

  test "member.read sees the top posters" do
    sign_in_as(reads_names)

    get active_journey_path

    assert_response :success
    assert_select ".empty-title", text: "Member names are not shown to you", count: 0
  end

  def backfiller
    scoped("backfill", "channel.read", "channel.backfill")
  end

  def syncer
    scoped("sync", "channel.read", "channel.backfill", "engine.sync")
  end

  def priceable_channel
    Analytics::DimChannel.where(archived: false).order(:channel_id).find do |channel|
      ChannelBackfill.estimate(channel).to_i.positive?
    end
  end

  test "somebody who only reads a channel cannot queue a backfill on it" do
    channel = some_channels(1).first
    open_up(channel, "everyone")
    sign_in_as(hold_role!("UCAREADER", "promethean"))

    assert_no_difference -> { ChannelBackfill.count } do
      post opt_in_channel_path(channel.channel_id)
    end

    assert_match(/Community manager only/, flash[:alert])
  end

  test "channel.backfill alone is stopped by the ceiling, and told what it would cost" do
    channel = priceable_channel
    skip "the seed priced no channel" if channel.nil?
    open_up(channel, "everyone")
    Engine::Setting.set!("engine", "backfill_ceiling", "0", by: @boss.user_id)
    sign_in_as(backfiller)

    assert_no_difference -> { ChannelBackfill.count } do
      post opt_in_channel_path(channel.channel_id)
    end

    assert_match(/needs engine.sync/, flash[:alert])
  end

  test "engine.sync is not stopped by the ceiling" do
    channel = priceable_channel
    skip "the seed priced no channel" if channel.nil?
    open_up(channel, "everyone")
    Engine::Setting.set!("engine", "backfill_ceiling", "0", by: @boss.user_id)
    sign_in_as(syncer)

    assert_difference -> { ChannelBackfill.count }, 1 do
      post opt_in_channel_path(channel.channel_id)
    end
  end

  test "no journey page ranks a channel you cannot see" do
    sign_in_as(holding_nothing)

    get newcomers_journey_path
    assert_response :success
    assert_select ".card-title", text: "Where newcomers land", count: 1
    assert_select "table.data-table a[href^='/channels/']", count: 0,
      message: "where newcomers land must not name a hidden channel"
  end

  test "the activity band chart needs channel.all, which sees every channel anyway" do
    sign_in_as(reads_names)
    get channels_path
    assert_response :success
    assert_select ".card-title", text: "Channels activity", count: 0,
      message: "band counts would difference out the hidden channels"

    sign_in_as(hold_role!("UCABANDS", "analytics"))
    get channels_path
    assert_response :success
  end

  test "a new role retires the old one and leaves the extra scopes alone" do
    staff = hold_role!("UCASWAP", "promethean")
    Authz::Grant.give!(staff.user_id, kind: "capability", name: "engine.sync", by: "test")
    hold_role!("UCASWAP", "gardener")
    Current.forget_roles

    assert_equal %w[gardener], Authz.roles_held(staff.user_id),
      "a second role replaces the first, it does not stack"
    assert_equal %w[engine.sync],
      Authz::Grant.live.for_person(staff.user_id).capabilities.pluck(:name),
      "swapping the role must not disturb the extra scopes"
  end
end
