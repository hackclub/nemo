require "test_helper"

class AdminScreensTest < ActionDispatch::IntegrationTest
  setup do
    @boss = hold_role!("UADBOSS", "community_manager")
  end

  test "every signed in person reaches their own account" do
    sign_in_as(Staff.create!(user_id: "UADNONE"))

    get account_path

    assert_response :success
    assert_select ".card-title", text: "What you hold"
  end

  test "holding nothing offers a way forward instead of three n/a rows" do
    sign_in_as(Staff.create!(user_id: "UADEMPTY"))

    get account_path

    assert_select ".empty-title", text: "Nothing yet"
    assert_select ".empty .btn", text: /Ask/
  end

  test "holding something names the role and what it lets you do" do
    sign_in_as(@boss)

    get account_path

    assert_select ".line-row b", text: "Role"
    assert_select ".line-row .chip-crit", text: /Community manager/
    assert_select ".reveal-body .mono", text: "access.grant"
  end

  test "the admin screens each render for a manager" do
    sign_in_as(@boss)

    [admin_people_path, admin_roles_path, admin_flags_path, admin_channels_path].each do |path|
      get path
      assert_response :success, "#{path} did not render"
    end
  end

  test "the roles matrix is one table over every capability and role" do
    sign_in_as(@boss)

    get admin_roles_path

    assert_response :success
    Authz.grantable_roles.reject { |r| Authz.superadmin?(r) }.each do |role|
      assert_select "thead th", text: /#{Authz.role_label(role)}/
    end
    assert_select "td.mono", text: "case.act"
    assert_select "td.mono", text: "engine.sync"
    assert_select "tr.band-row td", text: /Cases/
  end

  test "the roles matrix offers no family tab any more" do
    sign_in_as(@boss)

    get admin_roles_path

    %w[Reads Operates Observer Curator Steward Operator Analyst].each do |gone|
      assert_select "thead th", text: /#{gone}/, count: 0
      assert_select ".view", text: /#{gone}/, count: 0
    end
  end

  test "the roles matrix says how many sit off default" do
    sign_in_as(@boss)
    move_capability!("firefighter", "decision.settle", false, by: @boss.user_id)

    get admin_roles_path

    assert_select ".warnbar", text: /1 capability off the catalogue default/
    assert_select "form[action=?]", fd_role_permission_path
  end

  test "somebody holding nothing cannot administer access" do
    sign_in_as(Staff.create!(user_id: "UADOUT"))

    get admin_people_path

    assert_redirected_to root_path
  end

  test "a manager sets a channel audience" do
    channel = Analytics::DimChannel.where(archived: false).first
    sign_in_as(@boss)

    patch admin_channel_path(channel.channel_id), params: { audience: "public" }

    assert_redirected_to admin_channels_path
    assert_equal "public", Channels::Audience.of(channel.channel_id)
  end

  test "the analytics role cannot reach the admin section at all" do
    sign_in_as(hold_role!("UADANA", "analytics"))

    get admin_channels_path

    assert_redirected_to root_path
  end

  test "only a role holding access.grant reaches the admin section" do
    sign_in_as(hold_role!("UADCUR", "community_manager"))

    get admin_channels_path

    assert_response :success
  end

  test "the channel ledger bands by audience and counts each band" do
    channel = Analytics::DimChannel.where(archived: false).first
    Channels::Audience::Setting.create!(channel_id: channel.channel_id, audience: "public",
      set_by: @boss.user_id, set_at: Time.current)
    sign_in_as(@boss)

    get admin_channels_path

    assert_select "tr.band-row td", text: /Everyone signed in &middot; 1|Everyone signed in · 1/
    assert_select "td .chip-warn", text: "public"
    assert_select ".panel-head span", text: /1 are public/
  end

  test "the analytics role cannot set a channel audience" do
    staff = hold_role!("UADANA2", "analytics")
    channel = Analytics::DimChannel.where(archived: false).first
    sign_in_as(staff)

    patch admin_channel_path(channel.channel_id), params: { audience: "public" }

    assert_equal "granted", Channels::Audience.of(channel.channel_id)
  end

  test "an unknown audience is refused" do
    sign_in_as(@boss)
    channel = Analytics::DimChannel.where(archived: false).first

    patch admin_channel_path(channel.channel_id), params: { audience: "world" }

    assert_match(/not an audience/, flash[:alert])
    assert_equal "granted", Channels::Audience.of(channel.channel_id)
  end

  test "the account menu is how you reach your account and the admin section" do
    sign_in_as(@boss)
    get root_path

    assert_select ".you-pop a[href=?]", account_path
    assert_select ".you-pop a[href=?]", admin_root_path
  end

  test "somebody holding nothing still reaches their own account from the menu" do
    sign_in_as(Staff.create!(user_id: "UADMENU"))
    get root_path

    assert_select ".you-pop a[href=?]", account_path
    assert_select ".you-pop a[href=?]", admin_root_path, count: 0
  end
end
