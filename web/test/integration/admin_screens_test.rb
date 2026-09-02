require "test_helper"

class AdminScreensTest < ActionDispatch::IntegrationTest
  setup do
    @boss = Staff.create!(user_id: "UADBOSS", community_manager: true)
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
    assert_select ".line-row b", count: 0
    assert_select ".empty .btn", text: /Ask/
  end

  test "holding something names every family and what it lets you do" do
    sign_in_as(@boss)

    get account_path

    assert_select ".line-row b", text: "Fire Department"
    assert_select ".line-row b", text: "Reads"
    assert_select ".line-row b", text: "Operates"
    assert_select ".reveal-body .mono", text: "analytics.grant"
  end

  test "the admin screens each render for a manager" do
    sign_in_as(@boss)

    [admin_people_path, admin_roles_path, admin_product_path, admin_channels_path].each do |path|
      get path
      assert_response :success, "#{path} did not render"
    end
  end

  test "the roles matrix has a tab per family, each carrying its key count" do
    sign_in_as(@boss)

    get admin_roles_path(family: "read")

    assert_response :success
    assert_select ".view[aria-current]", text: /Reads/
    assert_select ".view[aria-current] .view-count", text: "5"
  end

  test "a fixed ladder draws rungs, each listing only what it adds" do
    sign_in_as(@boss)

    get admin_roles_path(family: "read")

    assert_select ".fbox .ft span", text: "Observer"
    assert_select ".fbox .ft span", text: "Analyst, plus"
    assert_select ".fbox .fb .mono", text: "analytics.workspace.read"
    assert_select ".fbox .fb .mono", text: "analytics.member.read"
  end

  test "the fire department matrix says how many sit off default" do
    sign_in_as(@boss)
    Fd::RolePermission.set!("firefighter", "decision.settle", true, by: @boss.user_id)

    get admin_roles_path(family: "fd")

    assert_select ".panel-head span", text: /1 moved off default/
    assert_select "form[action=?]", fd_role_permission_path
  end

  test "somebody holding nothing cannot administer access" do
    sign_in_as(Staff.create!(user_id: "UADOUT"))

    get admin_people_path

    assert_redirected_to root_path
  end

  test "a curator sets a channel audience" do
    staff = Staff.create!(user_id: "UADCUR")
    Community::Grant.give!(staff.user_id, role: "curator", by: @boss.user_id)
    channel = Analytics::DimChannel.where(archived: false).first
    sign_in_as(staff)

    patch admin_channel_path(channel.channel_id), params: { audience: "everyone" }

    assert_redirected_to admin_channels_path
    assert_equal "everyone", Channels::Audience.of(channel.channel_id)
  end

  test "the channel ledger bands by audience and counts each band" do
    channel = Analytics::DimChannel.where(archived: false).first
    Channels::Audience::Setting.create!(channel_id: channel.channel_id, audience: "everyone",
      set_by: @boss.user_id, set_at: Time.current)
    sign_in_as(@boss)

    get admin_channels_path

    assert_select "tr.band-row td", text: /Everyone &middot; 1|Everyone · 1/
    assert_select "td .chip-warn", text: "everyone"
    assert_select ".panel-head span", text: /are not private/
  end

  test "an analyst cannot set a channel audience" do
    staff = Staff.create!(user_id: "UADANA")
    Community::Grant.give!(staff.user_id, role: "analyst", by: @boss.user_id)
    channel = Analytics::DimChannel.where(archived: false).first
    sign_in_as(staff)

    patch admin_channel_path(channel.channel_id), params: { audience: "everyone" }

    assert_equal "private", Channels::Audience.of(channel.channel_id)
  end

  test "an unknown audience is refused" do
    sign_in_as(@boss)
    channel = Analytics::DimChannel.where(archived: false).first

    patch admin_channel_path(channel.channel_id), params: { audience: "world" }

    assert_match(/not an audience/, flash[:alert])
    assert_equal "private", Channels::Audience.of(channel.channel_id)
  end

  test "the account menu is how you reach your account and the admin section" do
    sign_in_as(@boss)
    get root_path

    assert_select ".you-pop a[href=?]", account_path
    assert_select ".you-pop a[href=?]", admin_people_path
  end

  test "somebody holding nothing still reaches their own account from the menu" do
    sign_in_as(Staff.create!(user_id: "UADMENU"))
    get root_path

    assert_select ".you-pop a[href=?]", account_path
    assert_select ".you-pop a[href=?]", admin_people_path, count: 0
  end
end
