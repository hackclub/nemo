require "test_helper"

class AccessUiTest < ActionDispatch::IntegrationTest
  setup do
    @boss = hold_role!("UAUIBOSS", "community_manager")
    @them = Account.create!(user_id: "UAUITHEM")
    hold_role!(@them.user_id, "firefighter")
    Current.forget_roles
    sign_in_as(@boss)
  end

  def held
    Current.forget_roles
    Authz.held(@them.user_id)
  end

  test "the manage page shows the role and what they hold" do
    get admin_person_path(@them.user_id)

    assert_response :success
    assert_select ".tile-t", text: "Role"
    assert_select ".tile-t", text: "In force"
    assert_select ".panel-head span", text: "Channels they read"
  end

  test "a manager takes one capability off a firefighter, and puts it back" do
    assert_includes held.keys, "slack.link"

    patch admin_person_capability_path(@them.user_id),
      params: { key: "slack.link", effect: "deny" }
    assert_redirected_to admin_person_path(@them.user_id)
    assert_not_includes held.keys, "slack.link", "the deny takes it off them"

    delete admin_person_capability_path(@them.user_id), params: { key: "slack.link" }
    assert_includes held.keys, "slack.link", "back to the role default"
  end

  test "a manager gives a capability no role carries" do
    assert_not_includes held.keys, "channel.backfill"

    patch admin_person_capability_path(@them.user_id),
      params: { key: "channel.backfill", effect: "allow" }

    assert_equal "added", held["channel.backfill"]
  end

  test "the locked granting capability cannot be handed out" do
    patch admin_person_capability_path(@them.user_id),
      params: { key: "access.grant", effect: "allow" }

    assert_match(/cannot be handed out/, flash[:alert])
    assert_not_includes held.keys, "access.grant"
  end

  test "naming a firefighter on a channel keeps their role, and they can already see it" do
    channel = Analytics::DimChannel.where(archived: false).first
    assert_not_includes held.keys, "channel.read"

    post admin_person_channel_grants_path(@them.user_id),
      params: { channel_id: channel.channel_id }

    assert_equal ["firefighter"], Authz.roles_held(@them.user_id), "they are not demoted"
    assert_not_includes held.keys, "channel.read", "everybody already holds it, nothing to add"
    assert Channels::Audience.may_see?(@them, channel)
  end

  test "naming somebody with no role on a channel makes them a promethean" do
    channel = Analytics::DimChannel.where(archived: false).first
    bare = Account.create!(user_id: "UAUIBARE2")

    post admin_person_channel_grants_path(bare.user_id),
      params: { channel_id: channel.channel_id }
    Current.forget_roles

    assert_equal ["promethean"], Authz.roles_held(bare.user_id)
    assert Channels::Audience.may_see?(bare, channel)
  end

  test "a channel that is not a channel is refused" do
    post admin_person_channel_grants_path(@them.user_id), params: { channel_id: "C0NOPE" }

    assert_match(/is not a channel/, flash[:alert])
  end

  test "the gardener set is shared, and says how many it reaches" do
    channel = Analytics::DimChannel.where(archived: false).first
    Authz::Grant.give!(@them.user_id, kind: "role", name: "gardener", by: @boss.user_id)
    Current.forget_roles

    post admin_role_channels_path(role: "gardener"), params: { channel_id: channel.channel_id }
    get admin_role_channels_path(role: "gardener")

    assert_response :success
    assert_select ".warnbar", text: /gardener/
    Current.forget_roles
    assert Channels::Audience.may_see?(@them, channel), "the set reaches everyone holding the role"
  end

  test "a member with no grant sees what they hold on their own page" do
    bare = Account.create!(user_id: "UAUIBARE")
    sign_in_as(bare)

    get account_path

    assert_response :success
    assert_select ".panel-head span", text: "What you can do"
  end
end
