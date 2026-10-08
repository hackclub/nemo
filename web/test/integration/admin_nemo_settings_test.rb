require "test_helper"

class AdminNemoSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def setting(key) = Fd::AppSetting.value(key)

  def sweep(**over)
    post admin_settings_sweep_path, params: { soon_hours: "12", tells: "1" }.merge(over)
  end

  test "the settings page carries both" do
    get admin_settings_path

    assert_response :success
    assert_match(/Channels Nemo joins/, response.body)
    assert_match(/Guard expiry/, response.body)
  end

  test "the join mode is set here" do
    post admin_settings_join_mode_path, params: { mode: "on" }

    assert_equal "on", Fd::AppSetting.join_mode
    assert_equal 1, Fd::AuditEntry.where(entity_type: "app_setting", verb: "tuned").count
  end

  test "a join mode that is not one is refused" do
    post admin_settings_join_mode_path, params: { mode: "sideways" }

    assert_equal "guarded", Fd::AppSetting.join_mode
    assert_match(/not a valid join mode/, flash[:alert])
  end

  test "setting the mode it already has changes nothing" do
    post admin_settings_join_mode_path, params: { mode: "guarded" }

    assert_equal 0, Fd::AuditEntry.where(entity_type: "app_setting", verb: "tuned").count
  end

  test "the sweep horizon is saved" do
    sweep

    assert_equal 12, Fd::AppSetting.sweep_soon_hours
    assert Fd::AppSetting.sweep_tells_member?
  end

  test "the horizon falls back when it was never set" do
    assert_equal 36, Fd::AppSetting.sweep_soon_hours
    assert Fd::AppSetting.sweep_tells_member?
  end

  test "an horizon outside the range is refused" do
    sweep(soon_hours: "0")

    assert_empty setting(Fd::AppSetting::SWEEP_SOON_HOURS)
    assert_match(/from 1 to/, flash[:alert])
  end

  test "telling the member is turned off on its own" do
    sweep(tells: "")

    assert_equal 12, Fd::AppSetting.sweep_soon_hours
    assert_not Fd::AppSetting.sweep_tells_member?
  end

  test "the channels page shows the mode but cannot change it" do
    get fd_channels_path

    assert_response :success
    assert_no_match(/join_mode/, response.body)
  end

  test "somebody who is not a community manager is turned away" do
    drop_roles!("UME")
    hold_role!("UME", "firefighter")
    post admin_settings_join_mode_path, params: { mode: "on" }

    assert_equal "guarded", Fd::AppSetting.join_mode
  end
end
